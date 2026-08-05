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
/// Deliberately small: one request, one response, no pipelining, and no
/// request streaming. The Noise session MAY be reused across exchanges
/// (`OpenPersistent` — see `ClawSiteRelayStreamOpener`), but each target is
/// still its own fresh backend connection (the engine calls `router.open`
/// per target, not once for the whole session) — a response's end is found
/// by `isResponseComplete` (`Content-Length`/chunked framing) regardless,
/// because whether THIS particular backend closes on its own is not
/// something the client can rely on either way, reused session or not.
public enum ClawSiteHTTPCodec {
    public enum CodecError: Error, Equatable, Sendable {
        case requestNotEncodable
        case responseHeaderIncomplete
        case responseStatusLineMalformed
        case responseChunkMalformed
        /// The response headers are complete but declare neither
        /// `Content-Length` nor `Transfer-Encoding: chunked`. V1 refuses to
        /// guess a body's end from the peer closing the connection: a target
        /// stream reused across exchanges (`OpenPersistent`) may sit on a
        /// backend that never closes on its own, so falling back to
        /// read-to-EOF would hang instead of failing. SSE, WebSocket
        /// upgrades, and any other unframed response are explicitly out of
        /// scope for this reason.
        case responseFramingUnsupported
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
        // Correct per-target regardless of Noise-session reuse: each target
        // is still its own fresh backend connection (`router.open` runs once
        // PER target, not once for the whole session — see
        // `ClawSiteRelayStreamOpener`). Not relied on for completion either
        // way, though: `isResponseComplete` decides that from the bytes
        // themselves, because a backend closing and the client's own
        // completion check are an inherent race the relay session's
        // idempotent close (see the Rust `send_close` doc) exists to absorb.
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

    private static func parseHeadBlock(
        _ headData: Data
    ) throws -> (statusCode: Int, httpVersion: String, headers: [(name: String, value: String)]) {
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
        return (statusCode, httpVersion, headers)
    }

    /// Parse a complete raw HTTP/1.1 response.
    ///
    /// Body length is resolved in the order the RFC requires: `Transfer-Encoding:
    /// chunked` wins over `Content-Length`, and only if neither is present does
    /// the body run to EOF. Getting that order wrong is how chunk-size lines end
    /// up rendered as page content, so it is pinned by tests rather than assumed
    /// from whatever the one server we tried happened to send. Callers that read
    /// from a target stream that may not close on its own (`OpenPersistent`)
    /// should call `isResponseComplete` first — `parseResponse` itself trusts
    /// `raw` to already be a full response and reads to EOF as a last resort.
    public static func parseResponse(_ raw: Data) throws -> Response {
        guard let separator = raw.firstRange(of: Data("\r\n\r\n".utf8)) else {
            throw CodecError.responseHeaderIncomplete
        }
        let headData = raw[raw.startIndex..<separator.lowerBound]
        let bodyData = raw[separator.upperBound...]
        let (statusCode, httpVersion, headers) = try parseHeadBlock(Data(headData))

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

    /// Whether `accumulated` already holds one complete HTTP/1.1 response, so
    /// a caller reading from a target stream knows it can stop and call
    /// `parseResponse` — WITHOUT waiting for the stream to close. Resolves
    /// framing in the same RFC order as `parseResponse` (chunked over
    /// `Content-Length`), and throws `responseFramingUnsupported` the moment
    /// a complete header block declares neither: on a persistent target the
    /// backend may keep its connection open indefinitely, so unframed
    /// responses (SSE, WebSocket, anything relying on connection-close) have
    /// no safe completion signal here and are refused rather than hung on.
    public static func isResponseComplete(_ accumulated: Data) throws -> Bool {
        guard let separator = accumulated.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        let headData = accumulated[accumulated.startIndex..<separator.lowerBound]
        let bodyData = accumulated[separator.upperBound...]
        let (_, _, headers) = try parseHeadBlock(Data(headData))

        let transferEncoding = headers
            .first { $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }?
            .value
            .lowercased()
        if transferEncoding?.contains("chunked") == true {
            return try chunkedBodyIsComplete(Data(bodyData))
        }
        if let lengthValue = headers
            .first(where: { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame })?
            .value,
            let length = Int(lengthValue.trimmingCharacters(in: .whitespaces)),
            length >= 0 {
            return bodyData.count >= length
        }
        throw CodecError.responseFramingUnsupported
    }

    /// Whether `body` (the bytes accumulated so far after the header block)
    /// already contains a complete chunked-encoded body, i.e. has reached the
    /// terminal 0-size chunk. Mirrors `decodeChunked`'s parsing exactly, but
    /// a short read returns `false` (keep waiting) instead of throwing —
    /// only a chunk-size line that is fully present and still fails to parse
    /// as hex is a genuine `responseChunkMalformed`, not truncation.
    private static func chunkedBodyIsComplete(_ body: Data) throws -> Bool {
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard let lineEnd = body[cursor...].firstRange(of: Data("\r\n".utf8)) else {
                return false
            }
            let sizeLine = body[cursor..<lineEnd.lowerBound]
            guard let sizeText = String(data: Data(sizeLine), encoding: .utf8) else {
                throw CodecError.responseChunkMalformed
            }
            let sizeToken = sizeText.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeText
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw CodecError.responseChunkMalformed
            }
            if size == 0 {
                // The terminal chunk is not complete until the trailer
                // section's blank-line terminator has actually arrived — with
                // no trailers that's immediately another `\r\n` (`0\r\n\r\n`
                // in full); reporting completion at `0\r\n` alone can leave
                // that trailing CRLF (or a real trailer block) unread on the
                // wire, where it corrupts the NEXT reused session's first
                // frame of its own target (see `send_close`'s doc on the Rust
                // side for the other half of this same class of bug).
                // `\r\n\r\n` anywhere from the size line's own CRLF onward is
                // the correct terminator whether or not there are trailers:
                // trailer header VALUES cannot contain a raw CRLF.
                return body[lineEnd.lowerBound...].firstRange(of: Data("\r\n\r\n".utf8)) != nil
            }
            let chunkStart = lineEnd.upperBound
            guard let chunkEnd = body.index(chunkStart, offsetBy: size, limitedBy: body.endIndex),
                  chunkEnd <= body.endIndex
            else {
                return false
            }
            guard let afterCRLF = body.index(chunkEnd, offsetBy: 2, limitedBy: body.endIndex) else {
                return false
            }
            cursor = afterCRLF
        }
        return false
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
