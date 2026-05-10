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
                let data = try await BootstrapWire.send(
                    method: "GET", url: url, body: nil, authorization: nil, perform: perform
                )
                return try Self.decode(data)
            } catch BootstrapError.serverError(let code, _) where code == "engine_initializing" {
                lastError = .serverError(code: code, message: nil)
                continue
            } catch let error as BootstrapError {
                throw error
            }
        }
        throw lastError
    }

    // MARK: - Decode

    private static func decode(_ data: Data) throws -> BootstrapStatusResponse {
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
}
