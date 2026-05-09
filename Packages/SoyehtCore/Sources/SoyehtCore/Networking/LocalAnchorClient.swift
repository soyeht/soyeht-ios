import Foundation
import Network

/// Client for `POST /pair-machine/local/anchor` against the candidate
/// machine. The iPhone owner posts the trust anchor — `(hh_id, hh_pub)`
/// gated by the install-time `anchor_secret` from the QR — before
/// authorising the founder Mac to finalize the join. Without a successful
/// anchor pin, the candidate's `local/finalize` endpoint refuses any
/// `JoinResponse` with `401 trust_anchor_missing`, defeating the B7
/// self-mint attack.
///
/// Source of truth for wire shape, ordering, and recovery semantics:
/// `theyos/specs/003-machine-join/contracts/local-anchor.md`.
public struct LocalAnchorClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let path = "/pair-machine/local/anchor"

    /// Per-attempt request timeout. Picked so a single hung TCP connect
    /// does not eat the whole 30s retry budget on its own.
    public static let perAttemptTimeoutSeconds: TimeInterval = 8

    /// Cap on cumulative wall-clock retry time. Backend contract specifies
    /// up to 30 s; the operator is staring at a spinner for the duration so
    /// further extensions would degrade UX without security benefit.
    public static let totalRetryBudgetSeconds: TimeInterval = 30

    /// Exponential backoff schedule (seconds). Cumulative ≈ 15 s; with the
    /// per-attempt timeout this fits inside the 30 s wall-clock cap even
    /// when the candidate is silently dropping packets.
    static let backoffScheduleSeconds: [TimeInterval] = [0.5, 1, 2, 4, 8]

    private let perform: TransportPerform
    private let sleeper: @Sendable (UInt64) async throws -> Void

    public init(
        transport: @escaping TransportPerform = LocalAnchorClient.plainHTTPTransport()
    ) {
        self.init(transport: transport, sleeper: { try await Task.sleep(nanoseconds: $0) })
    }

    init(
        transport: @escaping TransportPerform,
        sleeper: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.perform = transport
        self.sleeper = sleeper
    }

    public static func urlSessionTransport(_ session: URLSession = .shared) -> TransportPerform {
        { request in try await session.data(for: request) }
    }

    /// URLSession enforces App Transport Security before opening the socket.
    /// `NSAllowsLocalNetworking` covers LAN hosts such as `.local` and RFC1918
    /// addresses, but iOS does not classify Tailscale's 100.64/10 CGNAT range
    /// as local. The anchor POST is intentionally plain HTTP over a trusted
    /// local underlay, so use Network.framework for this narrow client instead
    /// of weakening ATS for the whole app.
    public static func plainHTTPTransport() -> TransportPerform {
        { request in try await PlainHTTPTransaction(request: request).perform() }
    }

    /// POST the trust anchor and wait for `LocalAnchorAck` (CBOR `{v:1}`).
    /// Retries transient transport failures (no route to host, DNS, refused
    /// connect, server 5xx) with exponential backoff up to
    /// `totalRetryBudgetSeconds`. **Does not retry** authoritative 401
    /// rejections — anchor_secret mismatch or `(hh_id, hh_pub)` collision
    /// surfaces immediately as the operator must regenerate the QR.
    public func pinAnchor(
        candidateAddress: String,
        anchorSecret: Data,
        householdId: String,
        householdPublicKey: Data
    ) async throws {
        guard let url = Self.endpointURL(candidateAddress: candidateAddress) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let body = HouseholdCBOR.localAnchor(
            anchorSecret: anchorSecret,
            householdId: householdId,
            householdPublicKey: householdPublicKey
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(JoinRequestStagingClient.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(JoinRequestStagingClient.contentType, forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.perAttemptTimeoutSeconds
        request.httpBody = body

        var lastTransientError: MachineJoinError = .networkDrop
        var elapsed: TimeInterval = 0
        let backoff = Self.backoffScheduleSeconds

        for attempt in 0...backoff.count {
            do {
                try await sendOnce(request)
                return
            } catch let error as MachineJoinError where Self.isRetryable(error) {
                lastTransientError = error
            } catch {
                throw error
            }

            guard attempt < backoff.count else { break }
            let delay = backoff[attempt]
            guard elapsed + delay <= Self.totalRetryBudgetSeconds else { break }
            try await sleeper(UInt64(delay * 1_000_000_000))
            elapsed += delay
        }
        throw lastTransientError
    }

    /// Path that produces `http://<host>:<port>/pair-machine/local/anchor`.
    /// `candidateAddress` is the bare authority (`host:port`) the candidate
    /// printed in the QR's `addr` param — never a full URL.
    /// Plain HTTP is intentional: confidentiality comes from the underlay
    /// (Tailscale or LAN broadcast domain). The CBOR body is bound to a
    /// per-install `anchor_secret`; an attacker on-path cannot forge a
    /// matching pin without the secret.
    static func endpointURL(candidateAddress: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        let trimmed = candidateAddress.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.lastIndex(of: ":"),
           let port = Int(trimmed[trimmed.index(after: colon)...]) {
            components.host = String(trimmed[..<colon])
            components.port = port
        } else {
            components.host = trimmed
        }
        components.path = Self.path
        return components.url
    }

    private func sendOnce(_ request: URLRequest) async throws {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.networkDrop
        }

        guard let http = response as? HTTPURLResponse else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard JoinRequestStagingClient.isCBORContentType(contentType) else {
            throw MachineJoinError.protocolViolation(detail: .wrongContentType(returned: contentType))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw try JoinRequestStagingClient.decodeErrorEnvelope(data)
        }
        try Self.decodeAck(data)
    }

    private static func decodeAck(_ data: Data) throws {
        guard case .map(let map) = try JoinRequestStagingClient.decodeCanonical(data) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        // Fail-closed allowlist mirroring `JoinRequestStagingClient`.
        try HouseholdCBORMapKeys.requireRequired(map, keys: ["v"])
        try HouseholdCBORMapKeys.requireKnown(map, keys: ["v"])
        guard case .unsigned(1) = map["v"] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    /// Transport-layer hiccups (timeouts, refused connect, no route) are
    /// retryable — the candidate may still be coming up or the network may
    /// flap. Server-issued errors (`serverError`, protocol violations) are
    /// authoritative: the candidate explicitly answered, retrying changes
    /// nothing and risks corrupting a recoverable state per
    /// `local-anchor.md` §"Interaction with `local/finalize`".
    private static func isRetryable(_ error: MachineJoinError) -> Bool {
        switch error {
        case .networkDrop:
            return true
        default:
            return false
        }
    }
}

private final class PlainHTTPTransaction: @unchecked Sendable {
    private let request: URLRequest
    private let url: URL
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.soyeht.local-anchor.plain-http")
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var responseBuffer = Data()
    private var timeoutWorkItem: DispatchWorkItem?
    private var isFinished = false
    private var didSend = false

    init(request: URLRequest) throws {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        self.request = request
        self.url = url
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func perform() async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let timeout = request.timeoutInterval > 0
                ? request.timeoutInterval
                : LocalAnchorClient.perAttemptTimeoutSeconds
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finish(.failure(MachineJoinError.networkDrop))
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
        case .failed, .waiting:
            finish(.failure(MachineJoinError.networkDrop))
        case .cancelled:
            finish(.failure(MachineJoinError.networkDrop))
        default:
            break
        }
    }

    private func sendRequestIfNeeded() {
        guard !didSend else { return }
        didSend = true

        let bytes: Data
        do {
            bytes = try Self.serialize(request: request)
        } catch {
            finish(.failure(error))
            return
        }

        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                if error != nil {
                    self?.finish(.failure(MachineJoinError.networkDrop))
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
                    self.finish(.failure(MachineJoinError.networkDrop))
                    return
                }
                if let data, !data.isEmpty {
                    self.responseBuffer.append(data)
                }

                do {
                    if let parsed = try Self.parseResponse(
                        self.responseBuffer,
                        url: self.url,
                        allowEOFBody: isComplete
                    ) {
                        self.finish(.success(parsed))
                    } else if isComplete {
                        self.finish(.failure(MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)))
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

    private static func serialize(request: URLRequest) throws -> Data {
        guard let url = request.url,
              let host = url.host else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }

        let body = request.httpBody ?? Data()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        if let query = components?.percentEncodedQuery {
            path += "?\(query)"
        }

        var headers = request.allHTTPHeaderFields ?? [:]
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

    private static func hostHeader(host: String, port: Int?) -> String {
        let hostValue = host.contains(":") ? "[\(host)]" : host
        guard let port, port != 80 else { return hostValue }
        return "\(hostValue):\(port)"
    }

    private static func setHeader(_ name: String, _ value: String, in headers: inout [String: String]) {
        for key in headers.keys where key.caseInsensitiveCompare(name) == .orderedSame {
            headers.removeValue(forKey: key)
        }
        headers[name] = value
    }

    private static func parseResponse(
        _ data: Data,
        url: URL,
        allowEOFBody: Bool
    ) throws -> (Data, URLResponse)? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter) else { return nil }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let availableBody = data[bodyStart...]
        let contentLength = headers.first { key, _ in
            key.caseInsensitiveCompare("Content-Length") == .orderedSame
        }.flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }

        let body: Data
        if let contentLength {
            guard availableBody.count >= contentLength else { return nil }
            body = Data(availableBody.prefix(contentLength))
        } else if allowEOFBody {
            body = Data(availableBody)
        } else {
            return nil
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return (body, response)
    }
}
