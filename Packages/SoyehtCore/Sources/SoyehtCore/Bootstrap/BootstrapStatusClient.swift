import Foundation

/// Client for `GET /bootstrap/status`.
///
/// Single fetch with automatic retry on `503 engine_initializing` (engine not yet
/// ready). Backoff schedule: [0.5s, 1s, 2s, 4s] before giving up.
///
/// Polling cadence (e.g. 500ms interval while installer screen is visible) is
/// the caller's responsibility — see `HealthCheckPoller` (T049).
public struct BootstrapStatusClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/status"

    /// Backoff delays (seconds) retried on `engine_initializing` 503.
    static let initializingBackoffSeconds: [TimeInterval] = [0.5, 1.0, 2.0, 4.0]

    /// States that indicate bootstrap is sufficiently advanced to stop polling.
    public static let terminalPollStates: Set<BootstrapState> = [
        .readyForNaming, .namedAwaitingPair, .ready,
    ]

    private static let requiredKeys: Set<String> = [
        "v", "state", "engine_version", "platform", "host_label", "device_count",
    ]
    private static let knownKeys: Set<String> = [
        "v", "state", "engine_version", "platform", "host_label",
        "owner_display_name", "device_count", "hh_id", "hh_pub",
    ]

    private let baseURL: URL
    private let perform: TransportPerform
    private let sleeper: @Sendable (UInt64) async throws -> Void

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.init(
            baseURL: baseURL,
            transport: transport,
            sleeper: { try await Task.sleep(nanoseconds: $0) }
        )
    }

    init(
        baseURL: URL,
        transport: @escaping TransportPerform,
        sleeper: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.baseURL = baseURL
        self.perform = transport
        self.sleeper = sleeper
    }

    /// Fetches status once, automatically retrying on `engine_initializing` 503.
    public func fetch() async throws -> BootstrapStatusResponse {
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        var lastError: BootstrapError = .networkDrop

        for (idx, delay) in ([TimeInterval(0)] + Self.initializingBackoffSeconds).enumerated() {
            if idx > 0 {
                try await sleeper(UInt64(delay * 1_000_000_000))
            }
            do {
                let body = try await Self.sendStatusRequest(url: url, perform: perform)
                switch body {
                case .cbor(let data):
                    return try Self.decodeCBOR(data)
                case .json(let data):
                    return try Self.decodeJSON(data)
                }
            } catch BootstrapError.serverError(let code, _) where code == "engine_initializing" {
                lastError = .serverError(code: code, message: nil)
                continue
            } catch let error as BootstrapError {
                throw error
            }
        }
        throw lastError
    }

    // MARK: - Send

    private enum StatusResponseBody {
        case cbor(Data)
        case json(Data)
    }

    private static func sendStatusRequest(
        url: URL,
        perform: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> StatusResponseBody {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("\(BootstrapWire.contentType), application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as BootstrapError {
            throw error
        } catch {
            throw BootstrapError.networkDrop
        }

        guard let http = response as? HTTPURLResponse else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard BootstrapWire.isCBORContentType(contentType) || isJSONContentType(contentType) else {
            throw BootstrapError.protocolViolation(detail: .wrongContentType(returned: contentType))
        }

        guard (200..<300).contains(http.statusCode) else {
            if BootstrapWire.isCBORContentType(contentType) {
                throw BootstrapWire.decodeError(data)
            }
            throw decodeJSONError(data)
        }

        if BootstrapWire.isCBORContentType(contentType) {
            return .cbor(data)
        }
        return .json(data)
    }

    private static func isJSONContentType(_ value: String?) -> Bool {
        value?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == "application/json"
    }

    private static func decodeJSONError(_ data: Data) -> BootstrapError {
        struct JSONErrorEnvelope: Decodable {
            let error: String?
            let code: String?
            let message: String?
        }

        guard let envelope = try? JSONDecoder().decode(JSONErrorEnvelope.self, from: data),
              let code = envelope.code ?? envelope.error else {
            return .protocolViolation(detail: .malformedErrorBody)
        }
        return .serverError(code: code, message: envelope.message)
    }

    // MARK: - Decode

    private static func decodeCBOR(_ data: Data) throws -> BootstrapStatusResponse {
        guard case .map(let map) = try BootstrapWire.decodeCanonical(data) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        do {
            try HouseholdCBORMapKeys.requireRequired(map, keys: requiredKeys)
            try HouseholdCBORMapKeys.requireKnown(map, keys: knownKeys)
        } catch {
            throw BootstrapError.protocolViolation(detail: .missingRequiredField)
        }
        guard case .unsigned(1) = map["v"] else {
            throw BootstrapError.protocolViolation(detail: .unsupportedEnvelopeVersion(
                (map["v"].flatMap { if case .unsigned(let u) = $0 { u } else { nil } }) ?? 0
            ))
        }
        guard case .text(let stateRaw) = map["state"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard let state = BootstrapState(rawValue: stateRaw) else {
            throw BootstrapError.protocolViolation(detail: .unknownStateValue(stateRaw))
        }
        guard case .text(let engineVersion) = map["engine_version"],
              case .text(let platform) = map["platform"],
              case .text(let hostLabel) = map["host_label"],
              case .unsigned(let deviceCount) = map["device_count"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        var ownerDisplayName: String?
        if let ownerVal = map["owner_display_name"], case .text(let name) = ownerVal {
            ownerDisplayName = name
        }

        var hhId: String?
        if let hhIdVal = map["hh_id"], case .text(let id) = hhIdVal {
            hhId = id
        }

        var hhPub: Data?
        if let hhPubVal = map["hh_pub"], case .bytes(let pub) = hhPubVal {
            guard pub.count == 33 else {
                throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
            }
            hhPub = pub
        }

        return BootstrapStatusResponse(
            version: 1,
            state: state,
            engineVersion: engineVersion,
            platform: platform,
            hostLabel: hostLabel,
            ownerDisplayName: ownerDisplayName,
            deviceCount: UInt8(min(deviceCount, UInt64(UInt8.max))),
            hhId: hhId,
            hhPub: hhPub
        )
    }

    private struct JSONStatusResponse: Decodable {
        let versionEnvelope: UInt64?
        let state: String
        let engineVersion: String?
        let legacyVersion: String?
        let platform: String
        let hostLabel: String
        let ownerDisplayName: String?
        let deviceCount: UInt64?
        let hhId: String?
        let hhPub: String?

        enum CodingKeys: String, CodingKey {
            case versionEnvelope = "v"
            case state
            case engineVersion = "engine_version"
            case legacyVersion = "version"
            case platform
            case hostLabel = "host_label"
            case ownerDisplayName = "owner_display_name"
            case deviceCount = "device_count"
            case hhId = "hh_id"
            case hhPub = "hh_pub"
        }
    }

    private static func decodeJSON(_ data: Data) throws -> BootstrapStatusResponse {
        let payload: JSONStatusResponse
        do {
            payload = try JSONDecoder().decode(JSONStatusResponse.self, from: data)
        } catch {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        guard payload.versionEnvelope ?? 1 == 1 else {
            throw BootstrapError.protocolViolation(detail: .unsupportedEnvelopeVersion(payload.versionEnvelope ?? 0))
        }
        guard let state = BootstrapState(rawValue: payload.state) else {
            throw BootstrapError.protocolViolation(detail: .unknownStateValue(payload.state))
        }
        guard let engineVersion = payload.engineVersion ?? payload.legacyVersion,
              let deviceCount = payload.deviceCount else {
            throw BootstrapError.protocolViolation(detail: .missingRequiredField)
        }

        let hhPub: Data?
        if let rawPub = payload.hhPub {
            hhPub = try decodeJSONBytes(rawPub)
            guard hhPub?.count == 33 else {
                throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
            }
        } else {
            hhPub = nil
        }

        return BootstrapStatusResponse(
            version: 1,
            state: state,
            engineVersion: engineVersion,
            platform: payload.platform,
            hostLabel: payload.hostLabel,
            ownerDisplayName: payload.ownerDisplayName,
            deviceCount: UInt8(min(deviceCount, UInt64(UInt8.max))),
            hhId: payload.hhId,
            hhPub: hhPub
        )
    }

    private static func decodeJSONBytes(_ value: String) throws -> Data {
        if let data = Data(base64Encoded: value) {
            return data
        }
        return try Data(soyehtBase64URL: value)
    }
}
