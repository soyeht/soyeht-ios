import Foundation

/// Acknowledgement returned by the pair-device window's open route.
///
/// `expiresAt` is the engine's own time box on the window (unix seconds). It is
/// advisory here: the Mac does not schedule off it, it re-opens on a fixed
/// interval well below the engine's TTL floor. It is carried so the app log can
/// state when the home stops being visible if the sheet is left open and the
/// renewals stop.
public struct BootstrapPairDeviceWindowAck: Equatable, Sendable {
    public let version: UInt64
    public let expiresAt: UInt64?

    public init(version: UInt64, expiresAt: UInt64?) {
        self.version = version
        self.expiresAt = expiresAt
    }
}

/// Opens or closes temporary LAN visibility through the loopback engine API.
/// The engine owns the deadline and reports it as `expires_at_unix`; this
/// operation does not mint a pairing token or prove that a listener has bound.
/// Consumers use the address snapshot to observe the completed bind.
public struct BootstrapPairDeviceWindowClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let openPath = "/bootstrap/local-network-visibility/open"
    static let closePath = "/bootstrap/local-network-visibility/close"

    private static let requiredKeys: Set<String> = ["v", "open", "expires_at_unix"]
    static let expiresAtKey = "expires_at_unix"
    private static let knownKeys: Set<String> = requiredKeys.union([expiresAtKey, "open"])

    private let baseURL: URL
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.perform = transport
    }

    /// Ask this Mac's engine to be visible on the local network. Safe to repeat:
    /// a repeat extends the window it already has.
    @discardableResult
    public func open() async throws -> BootstrapPairDeviceWindowAck {
        try await send(path: Self.openPath)
    }

    /// Ask this Mac's engine to stop being visible on the local network. Safe to
    /// repeat, and safe when no window is open.
    @discardableResult
    public func close() async throws -> BootstrapPairDeviceWindowAck {
        try await send(path: Self.closePath)
    }

    private func send(path: String) async throws -> BootstrapPairDeviceWindowAck {
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: path)
        let data = try await BootstrapWire.send(
            method: "POST",
            url: url,
            body: Self.encodeRequest(),
            authorization: nil,
            perform: perform
        )
        return try Self.decodeAck(data)
    }

    // MARK: - Encode

    static func encodeRequest() -> Data {
        HouseholdCBOR.encode(.map(["v": .unsigned(1)]))
    }

    // MARK: - Decode

    static func decodeAck(_ data: Data) throws -> BootstrapPairDeviceWindowAck {
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

        // `null` is not a malformed answer here, it is the CLOSE answer: the
        // engine's field is `Option<u64>` with no `skip_serializing_if`, so
        // every close carries `expires_at_unix: null`. Rejecting it would make
        // every close report a protocol violation while the engine had in fact
        // closed the window.
        let expiresAt: UInt64?
        switch map[Self.expiresAtKey] {
        case .some(.unsigned(let value)):
            expiresAt = value
        case .some(.null):
            expiresAt = nil
        default:
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        guard case .bool(let open) = map["open"], open == (expiresAt != nil) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return BootstrapPairDeviceWindowAck(version: 1, expiresAt: expiresAt)
    }
}
