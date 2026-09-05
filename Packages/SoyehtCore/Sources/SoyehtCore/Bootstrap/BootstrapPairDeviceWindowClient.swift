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
/// THE CONTRACT, as this client speaks it:
///   - `POST /bootstrap/pair-device/window/open` — body `{v: 1}` canonical
///     CBOR, no `Authorization` (the engine admits loopback only, the same
///     admission `POST /bootstrap/pair-device/reissue` uses). Idempotent and
///     time-boxed: opening an already-open window extends it rather than
///     minting anything or conflicting. Answers `{v: 1}`, optionally with
///     `expires_at`.
///   - `POST /bootstrap/pair-device/window/close` — body `{v: 1}`, same
///     admission. Idempotent: closing a closed window is a success.
///
/// The engine half is on `theyos` branch `engine/lan-pairing-optin` and is NOT
/// merged as of this file's first commit. Until it lands, both calls fail —
/// which is the designed outcome, because every caller here treats a failure as
/// "no LAN bonus" and carries on. If the engine names the routes differently,
/// `openPath`/`closePath` below are the only two lines to change.
public struct BootstrapPairDeviceWindowClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let openPath = "/bootstrap/pair-device/window/open"
    static let closePath = "/bootstrap/pair-device/window/close"

    private static let requiredKeys: Set<String> = ["v"]
    private static let knownKeys: Set<String> = requiredKeys.union(["expires_at"])

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

        let expiresAt: UInt64?
        if let expiresValue = map["expires_at"] {
            guard case .unsigned(let value) = expiresValue else {
                throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
            }
            expiresAt = value
        } else {
            expiresAt = nil
        }

        return BootstrapPairDeviceWindowAck(version: 1, expiresAt: expiresAt)
    }
}
