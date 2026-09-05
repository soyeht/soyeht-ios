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

/// Client for the pair-device window's open/close pair on this Mac's own engine.
///
/// WHY THIS EXISTS. The owner's rule is that the home is discoverable on the
/// local network in exactly two situations: while the household has not been
/// set up yet, and while an "Add iPhone" window is open. The engine half of the
/// second situation exists (`HouseholdExposurePolicy` grants
/// `InterfaceClass::Lan` post-onboarding only while a pairing window is Open,
/// and the listener reconciles on the window's broadcast and on a 500 ms tick).
/// Nothing on a household that is already set up ever opened that window:
/// the Add iPhone sheet shows an offer the Mac itself minted, and the only
/// route that opens an engine-side window is `GET /bootstrap/pair-device-uri`,
/// the FIRST-OWNER route, which answers 404 once an owner exists — measured
/// against the Dev engine on 2026-09-04: 404 with `device_count=1`. So the
/// policy saw `Closed` and the LAN never bound.
///
/// WHAT THIS ASKS FOR. Visibility, and nothing else. This client never mints,
/// reads or renews a pairing offer. The six words on the Add iPhone sheet come
/// from `MacPairingAdvertisement` and are untouched by open/close. It is
/// deliberately NOT `POST /bootstrap/pair-device/reissue`: that route mints a
/// NEW token and answers `409 window_still_open` when one is open, so calling
/// it would make the words on the Mac and the words the phone expects disagree
/// — a defect this codebase has already lived through once.
///
/// THE CONTRACT, read off the engine's own source
/// (`server-rs/src/local_network_visibility.rs`) rather than invented here —
/// the first version of this file made up its own names and its own response
/// key, and shipped green on both sides:
///   - `POST /bootstrap/local-network-visibility/open` — body `{v: 1}`
///     canonical CBOR, no `Authorization` (the engine admits loopback only, the
///     same admission `POST /bootstrap/pair-device/reissue` uses). The engine
///     IGNORES the body: the TTL is engine policy, not a caller's choice.
///     Idempotent and time-boxed — one slot, and opening while open replaces
///     the deadline rather than stacking a second grant. Answers
///     `{v: 1, open: true, expires_at_unix: <secs>}`.
///   - `POST /bootstrap/local-network-visibility/close` — body `{v: 1}`, same
///     admission. Idempotent: closing a closed window is a success. Answers
///     `{v: 1, open: false, expires_at_unix: null}` — the key is always
///     present, and `null` is how the engine says "no deadline", because its
///     `Option<u64>` carries no `skip_serializing_if`.
///
/// The engine half is on `theyos` branch `engine/lan-pairing-optin` and is NOT
/// merged as of this file's first commit. Until it lands, both calls fail —
/// which is the designed outcome, because every caller here treats a failure as
/// "no LAN bonus" and carries on.
public struct BootstrapPairDeviceWindowClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // These four literals ARE the contract with the engine
    // (theyos admin/rust/server-rs/src/local_network_visibility.rs). The first
    // version of this file invented its own names and shipped green: both
    // suites passed because each side pinned what it had made up, and the
    // feature would have been dead end to end — silently, since every caller
    // here treats a failure as "no Wi-Fi bonus" and carries on.
    // `theEngineServesTheRoutesThisClientCalls` compares them against the
    // engine's source when that repo is on disk.
    static let openPath = "/bootstrap/local-network-visibility/open"
    static let closePath = "/bootstrap/local-network-visibility/close"

    private static let requiredKeys: Set<String> = ["v"]
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
        case .none, .some(.null):
            expiresAt = nil
        default:
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        return BootstrapPairDeviceWindowAck(version: 1, expiresAt: expiresAt)
    }
}
