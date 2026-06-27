import Foundation
import Network

/// HTTP/1.1 request-response transport over a Unix domain socket.
///
/// This is intended for macOS local engine routes where the engine
/// authenticates the signed app peer from the accepted UDS connection. It is a
/// transport only: callers decide whether the request is owner-PoP signed or
/// local-socket caller-authenticated.
public struct UnixDomainSocketHTTPTransport: Sendable {
    public static let defaultTimeoutSeconds: TimeInterval = 15
    public static let maximumResponseBodyBytes = 1_048_576

    private let socketPath: String
    private let timeout: TimeInterval

    public init(
        socketPath: String,
        timeout: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await UnixDomainSocketHTTPTransaction(
            socketPath: socketPath,
            request: request,
            timeout: timeout
        ).perform()
    }

    public func transport() -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            try await perform(request)
        }
    }
}

final class UnixDomainSocketHTTPTransaction: @unchecked Sendable {
    private let request: URLRequest
    private let url: URL
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.soyeht.uds-http")
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var responseBuffer = Data()
    private var timeoutWorkItem: DispatchWorkItem?
    private var isFinished = false
    private var didSend = false

    init(socketPath: String, request: URLRequest, timeout: TimeInterval) throws {
        guard !socketPath.isEmpty else {
            throw BootstrapError.networkDrop
        }
        guard let url = request.url,
              url.scheme?.lowercased() == "http" else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        self.request = request
        self.url = url
        self.timeout = timeout > 0 ? timeout : UnixDomainSocketHTTPTransport.defaultTimeoutSeconds
        self.connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func perform() async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finish(.failure(BootstrapError.networkDrop))
            }
            self.timeoutWorkItem = timeoutWorkItem
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async { self?.handle(state) }
            }
            connection.start(queue: queue)
        }
    }

    private func handle(_ state: NWConnection.State) {
        guard !isFinished else { return }
        switch state {
        case .ready:
            sendRequestIfNeeded()
        case .failed, .waiting, .cancelled:
            finish(.failure(BootstrapError.networkDrop))
        default:
            break
        }
    }

    private func sendRequestIfNeeded() {
        guard !didSend else { return }
        didSend = true

        let bytes: Data
        do {
            bytes = try UnixDomainSocketHTTPFraming.serialize(request: request)
        } catch {
            finish(.failure(error))
            return
        }

        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                if error != nil {
                    self?.finish(.failure(BootstrapError.networkDrop))
                } else {
                    self?.receiveResponse()
                }
            }
        })
    }

    private func receiveResponse() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, !self.isFinished else { return }
                if error != nil {
                    self.finish(.failure(BootstrapError.networkDrop))
                    return
                }
                if let data, !data.isEmpty {
                    self.responseBuffer.append(data)
                }

                do {
                    try UnixDomainSocketHTTPFraming.validateBufferedResponseSize(self.responseBuffer)
                    if let parsed = try UnixDomainSocketHTTPFraming.parseResponse(self.responseBuffer, url: self.url) {
                        self.finish(.success(parsed))
                    } else if isComplete {
                        self.finish(.failure(BootstrapError.protocolViolation(detail: .unexpectedResponseShape)))
                    } else {
                        self.receiveResponse()
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let continuation = continuation
        self.continuation = nil

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

enum UnixDomainSocketHTTPFraming {
    static func validateBufferedResponseSize(_ data: Data) throws {
        guard data.count <= UnixDomainSocketHTTPTransport.maximumResponseBodyBytes else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    static func serialize(request: URLRequest) throws -> Data {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        let body = request.httpBody ?? Data()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        if let query = components?.percentEncodedQuery {
            path += "?\(query)"
        }

        var headers = request.allHTTPHeaderFields ?? [:]
        removeHeader("Transfer-Encoding", in: &headers)
        setHeader("Host", hostHeader(host: host, port: url.port), in: &headers)
        setHeader("Connection", "close", in: &headers)
        setHeader("Content-Length", String(body.count), in: &headers)

        var head = "\(request.httpMethod ?? "GET") \(path) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func parseResponse(_ data: Data, url: URL) throws -> (Data, URLResponse)? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter) else { return nil }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if let transferEncoding = headerValue("Transfer-Encoding", in: headers),
           transferEncoding.lowercased().contains("chunked") {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard let contentLengthText = headerValue("Content-Length", in: headers),
              let contentLength = Int(contentLengthText.trimmingCharacters(in: .whitespaces)),
              contentLength >= 0,
              contentLength <= UnixDomainSocketHTTPTransport.maximumResponseBodyBytes else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        let bodyStart = headerRange.upperBound
        let availableBody = data[bodyStart...]
        guard availableBody.count >= contentLength else { return nil }
        let body = Data(availableBody.prefix(contentLength))

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return (body, response)
    }

    private static func hostHeader(host: String, port: Int?) -> String {
        let hostValue = host.contains(":") ? "[\(host)]" : host
        guard let port, port != 80 else { return hostValue }
        return "\(hostValue):\(port)"
    }

    private static func setHeader(_ name: String, _ value: String, in headers: inout [String: String]) {
        removeHeader(name, in: &headers)
        headers[name] = value
    }

    private static func removeHeader(_ name: String, in headers: inout [String: String]) {
        for key in headers.keys where key.caseInsensitiveCompare(name) == .orderedSame {
            headers.removeValue(forKey: key)
        }
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}
