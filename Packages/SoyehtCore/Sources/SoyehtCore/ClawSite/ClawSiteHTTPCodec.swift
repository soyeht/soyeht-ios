import Foundation

/// Minimal HTTP/1.1 serialization and parsing for the ClawSite data plane.
///
/// The relay-stream tunnel carries **raw HTTP bytes** inside its frames — no
/// HTTP awareness anywhere between here and the claw's own web server (the
/// engine's `RelayStreamClawSiteRouter` is a plain TCP forwarder, and
/// `friend-cli`'s ClawSite smoke writes a literal request string and reads the
/// reply verbatim). So the guest has to speak HTTP itself, and these are the
/// two functions where that happens.
///
/// Deliberately small: one request, one response, `Connection: close`. There is
/// no connection reuse, no pipelining, and no request streaming — each request
/// gets its own tunnel session, which is what makes reading-until-EOF a
/// well-defined way to find the end of a response body.
public enum ClawSiteHTTPCodec {
    public enum CodecError: Error, Equatable, Sendable {
        case requestNotEncodable
        case responseHeaderIncomplete
        case responseStatusLineMalformed
        case responseChunkMalformed
    }

    /// Headers a guest must never forward verbatim. `Connection`/`Host` are
    /// re-derived below; the rest are hop-by-hop (RFC 9110 §7.6.1) and
    /// meaningless — or misleading — once the request is re-framed onto a
    /// different transport.
    private static let strippedRequestHeaders: Set<String> = [
        "connection",
        "host",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]

    /// Serialize a request into the exact bytes the claw's HTTP server will
    /// read off its socket.
    ///
    /// `host` is what lands in the `Host:` header. It is NOT a routing input —
    /// the tunnel already decided which claw it reaches — so a name-based
    /// vhost on the claw side sees a stable value rather than the guest's
    /// loopback/custom-scheme URL, which would mean nothing to it.
    public static func serializeRequest(
        method: String,
        path: String,
        host: String,
        headers: [String: String],
        body: Data?
    ) throws -> Data {
        let normalizedPath = path.isEmpty ? "/" : path
        var head = "\(method.uppercased()) \(normalizedPath) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        // Read-to-EOF is only a correct end-of-body signal because we ask the
        // server to close. Without this the response would hang until timeout.
        head += "Connection: close\r\n"

        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
        where !strippedRequestHeaders.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        if let body, !body.isEmpty {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"

        guard var out = head.data(using: .utf8) else {
            throw CodecError.requestNotEncodable
        }
        if let body, !body.isEmpty {
            out.append(body)
        }
        return out
    }

    public struct Response: Equatable, Sendable {
        public let statusCode: Int
        public let httpVersion: String
        /// Header names as the origin sent them (case preserved).
        public let headers: [(name: String, value: String)]
        public let body: Data

        public init(statusCode: Int, httpVersion: String, headers: [(name: String, value: String)], body: Data) {
            self.statusCode = statusCode
            self.httpVersion = httpVersion
            self.headers = headers
            self.body = body
        }

        public static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.statusCode == rhs.statusCode
                && lhs.httpVersion == rhs.httpVersion
                && lhs.body == rhs.body
                && lhs.headers.count == rhs.headers.count
                && zip(lhs.headers, rhs.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
        }

        public func headerValue(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// Flattened for `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)`.
        /// Repeated headers are joined with ", " per RFC 9110 §5.3. `Set-Cookie`
        /// is the documented exception to that rule, but a dictionary cannot
        /// represent it faithfully either way — this is a known limitation of
        /// the `headerFields` API, not of the parse above, which keeps every
        /// occurrence.
        public var headerFields: [String: String] {
            var fields: [String: String] = [:]
            for header in headers {
                if let existing = fields[header.name] {
                    fields[header.name] = "\(existing), \(header.value)"
                } else {
                    fields[header.name] = header.value
                }
            }
            return fields
        }
    }

    /// Parse a complete raw HTTP/1.1 response.
    ///
    /// Body length is resolved in the order the RFC requires: `Transfer-Encoding:
    /// chunked` wins over `Content-Length`, and only if neither is present does
    /// the body run to EOF. Getting that order wrong is how chunk-size lines end
    /// up rendered as page content, so it is pinned by tests rather than assumed
    /// from whatever the one server we tried happened to send.
    public static func parseResponse(_ raw: Data) throws -> Response {
        guard let separator = raw.firstRange(of: Data("\r\n\r\n".utf8)) else {
            throw CodecError.responseHeaderIncomplete
        }
        let headData = raw[raw.startIndex..<separator.lowerBound]
        let bodyData = raw[separator.upperBound...]

        guard let headText = String(data: headData, encoding: .utf8) else {
            throw CodecError.responseHeaderIncomplete
        }
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw CodecError.responseStatusLineMalformed }

        let statusLine = lines.removeFirst()
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1]),
              (100...599).contains(statusCode)
        else {
            throw CodecError.responseStatusLineMalformed
        }
        let httpVersion = String(statusParts[0])

        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers.append((name: name, value: value))
        }

        let transferEncoding = headers
            .first { $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }?
            .value
            .lowercased()
        let body: Data
        if transferEncoding?.contains("chunked") == true {
            body = try decodeChunked(Data(bodyData))
        } else if let lengthValue = headers
            .first(where: { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame })?
            .value,
            let length = Int(lengthValue.trimmingCharacters(in: .whitespaces)),
            length >= 0 {
            // Truncate to the declared length; a short read yields what arrived
            // rather than inventing padding.
            body = Data(bodyData.prefix(length))
        } else {
            body = Data(bodyData)
        }

        return Response(statusCode: statusCode, httpVersion: httpVersion, headers: headers, body: body)
    }

    /// Decode `Transfer-Encoding: chunked` into the raw entity body.
    static func decodeChunked(_ input: Data) throws -> Data {
        var out = Data()
        var cursor = input.startIndex

        while cursor < input.endIndex {
            guard let lineEnd = input[cursor...].firstRange(of: Data("\r\n".utf8)) else {
                throw CodecError.responseChunkMalformed
            }
            let sizeLine = input[cursor..<lineEnd.lowerBound]
            guard let sizeText = String(data: Data(sizeLine), encoding: .utf8) else {
                throw CodecError.responseChunkMalformed
            }
            // A chunk-size line may carry `;ext=value` chunk extensions.
            let sizeToken = sizeText.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeText
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw CodecError.responseChunkMalformed
            }
            if size == 0 {
                // Terminal chunk. Any trailer section that follows is dropped:
                // nothing downstream consumes trailers today, and silently
                // appending them to the body would corrupt it.
                return out
            }
            let chunkStart = lineEnd.upperBound
            guard let chunkEnd = input.index(chunkStart, offsetBy: size, limitedBy: input.endIndex),
                  chunkEnd <= input.endIndex
            else {
                throw CodecError.responseChunkMalformed
            }
            out.append(contentsOf: input[chunkStart..<chunkEnd])
            // Skip the CRLF that terminates the chunk data.
            guard let afterCRLF = input.index(chunkEnd, offsetBy: 2, limitedBy: input.endIndex) else {
                throw CodecError.responseChunkMalformed
            }
            cursor = afterCRLF
        }
        // Ran out of input without seeing the terminal 0-size chunk.
        throw CodecError.responseChunkMalformed
    }
}
