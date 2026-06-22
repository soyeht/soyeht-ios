import Foundation

/// Response from `POST /bootstrap/accept-household/confirm`. After this
/// call the fresh engine is fully joined: `bootstrap_state == "ready"`
/// and the household Bonjour publisher takes over `_soyeht-household._tcp.`.
public struct BootstrapAcceptHouseholdConfirmResponse: Sendable, Equatable {
    public let version: UInt64
    public let bootstrapState: String
    public let machineId: String
    public let householdId: String

    public init(version: UInt64, bootstrapState: String, machineId: String, householdId: String) {
        self.version = version
        self.bootstrapState = bootstrapState
        self.machineId = machineId
        self.householdId = householdId
    }
}

/// Client for `POST /bootstrap/accept-household/confirm`. Closes the
/// add-Mac handshake: iPhone forwards the household-signed MachineCert
/// and challenge signature it obtained from the existing member engine
/// (via `HouseholdSignMachineCertClient`) and the fresh engine commits
/// the membership atomically.
public struct BootstrapAcceptHouseholdConfirmClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/accept-household/confirm"

    private static let requiredKeys: Set<String> = ["v", "bootstrap_state", "m_id", "hh_id"]
    private static let knownKeys: Set<String> = requiredKeys

    private let baseURL: URL
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await BootstrapInitializeClient.defaultSession.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.perform = transport
    }

    /// - Parameters:
    ///   - machineId: The `m_id` returned by the prepare step.
    ///   - machineCert: Canonical CBOR of the signed MachineCert (opaque
    ///     to the iPhone; produced by the household-signing engine).
    ///   - challengeSig: 64-byte raw r||s P-256 signature over the
    ///     `joinChallenge` bytes returned by the prepare step.
    public func confirm(
        machineId: String,
        machineCert: Data,
        challengeSig: Data
    ) async throws -> BootstrapAcceptHouseholdConfirmResponse {
        guard challengeSig.count == 64 else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        // Pre-flight handshake: refuse engines older than
        // `EngineCompat.minSupportedEngineVersion` with a clear message before
        // the main POST. See `docs/engine-protocol-version.md`. This is the
        // final, atomic step of the add-Mac join, so an incompatible engine
        // here must fail loudly rather than commit a half-understood
        // membership — same gate the initialize / accept-household clients run.
        try await EngineCompat.assertCompatible(
            via: BootstrapStatusClient(baseURL: baseURL, transport: perform)
        )

        let body = Self.encodeRequest(
            machineId: machineId,
            machineCert: machineCert,
            challengeSig: challengeSig
        )
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let data = try await BootstrapWire.send(
            method: "POST", url: url, body: body, authorization: nil, perform: perform
        )
        return try Self.decode(data)
    }

    // MARK: - Encode

    static func encodeRequest(
        machineId: String,
        machineCert: Data,
        challengeSig: Data
    ) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "m_id": .text(machineId),
            "machine_cert": .bytes(machineCert),
            "challenge_sig": .bytes(challengeSig),
        ]))
    }

    // MARK: - Decode

    private static func decode(_ data: Data) throws -> BootstrapAcceptHouseholdConfirmResponse {
        guard case .map(let map) = try BootstrapWire.decodeCanonical(data) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        do {
            try HouseholdCBORMapKeys.requireRequired(map, keys: requiredKeys)
            try HouseholdCBORMapKeys.requireKnown(map, keys: knownKeys)
        } catch {
            throw BootstrapError.protocolViolation(detail: .missingRequiredField)
        }
        guard case .unsigned(1) = map["v"],
              case .text(let state) = map["bootstrap_state"],
              case .text(let mId) = map["m_id"],
              case .text(let hhId) = map["hh_id"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return BootstrapAcceptHouseholdConfirmResponse(
            version: 1,
            bootstrapState: state,
            machineId: mId,
            householdId: hhId
        )
    }
}
