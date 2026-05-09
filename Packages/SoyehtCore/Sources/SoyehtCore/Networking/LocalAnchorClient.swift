import Foundation

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
        transport: @escaping TransportPerform = LocalAnchorClient.urlSessionTransport()
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
