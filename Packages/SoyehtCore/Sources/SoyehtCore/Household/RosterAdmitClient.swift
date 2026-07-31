import Foundation

enum RosterClientErrorEnvelope {
    static let nonServerErrorLiterals: Set<String> = [
        "invalid_request", "query_not_allowed", "invalid_machine_id",
        "unauthenticated",
        "already_initialized",
        "payload_too_large", "body_not_allowed",
        "unsupported_media_type",
        "not_ready", "not_initialized", "clock_unavailable", "lock_timeout",
    ]

    static func allowedLiterals(for status: Int) -> Set<String>? {
        switch status {
        case 400: return ["invalid_request", "query_not_allowed", "invalid_machine_id"]
        case 401: return ["unauthenticated"]
        case 409: return ["already_initialized"]
        case 413: return ["payload_too_large", "body_not_allowed"]
        case 415: return ["unsupported_media_type"]
        case 503: return ["not_ready", "not_initialized", "clock_unavailable", "lock_timeout"]
        case 500: return RosterWire.knownErrorLiterals.subtracting(nonServerErrorLiterals)
        default: return nil
        }
    }

    static func decodeError(status: Int, data: Data) -> RosterWireError {
        guard case .serverError(let code) = RosterWire.decodeErrorEnvelope(data),
              let allowed = allowedLiterals(for: status),
              allowed.contains(code) else {
            return .malformedResponse
        }
        return .serverError(code: code)
    }
}

public struct RosterAdmitResponse: Sendable, Equatable {
    public let v: UInt64
    public let outcome: String
}

public enum RosterAdmitClientError: Error, Equatable, Sendable {
    case wire(RosterWireError)
    case httpStatus(Int)
    case transportFailed
}

public struct RosterAdmitClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/household/roster/admit"

    static let outcomes: Set<String> = [
        "accepted",
        "idempotent_duplicate",
        "rejected_replay",
        "rejected_gap",
        "rejected_rollback",
        "rejected_malformed",
        "rejected_owner",
        "rejected_caveat",
        "rejected_signature",
        "rejected_temporal",
        "rejected_projection",
        "epoch_migration_required",
        "checkpoint_fork_conflict_recorded",
        "event_fork_conflict_recorded",
    ]

    private let baseURL: URL
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(baseURL: URL, popSigner: HouseholdPoPSigner, perform: @escaping TransportPerform) {
        self.baseURL = baseURL
        self.popSigner = popSigner
        self.perform = perform
    }

    public func admit(checkpointBytes: Data) async throws -> RosterAdmitResponse {
        let (url, pathAndQuery) = try RosterWire.endpointURL(baseURL: baseURL, path: Self.path)
        guard checkpointBytes.count <= RosterWire.admitBodyLimit else {
            throw RosterAdmitClientError.wire(.payloadTooLarge)
        }
        let authorization = try popSigner.authorization(
            method: "POST",
            pathAndQuery: pathAndQuery,
            body: checkpointBytes
        ).authorizationHeader

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(RosterWire.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = checkpointBytes

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw RosterAdmitClientError.transportFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw RosterAdmitClientError.transportFailed
        }
        try RosterWire.validateResponseContentType(http.value(forHTTPHeaderField: "Content-Type"))
        guard http.statusCode == 200 else {
            throw RosterAdmitClientError.wire(
                RosterClientErrorEnvelope.decodeError(status: http.statusCode, data: data)
            )
        }
        let decoded = try RosterWire.decodeCanonical(data)
        guard case .map(let map) = decoded else {
            throw RosterAdmitClientError.wire(.unexpectedKeySet)
        }
        try RosterWire.requireExactKeys(map, ["outcome", "v"])
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterAdmitClientError.wire(.malformedResponse) }
        let outcome = try RosterWire.requireText(map, "outcome")
        guard Self.outcomes.contains(outcome) else { throw RosterAdmitClientError.wire(.malformedResponse) }
        return RosterAdmitResponse(v: v, outcome: outcome)
    }
}
