import Foundation

/// Response from `POST /bootstrap/accept-household`. The iPhone takes
/// `joinChallenge` to a member engine (e.g. Linux) for signing via
/// `HouseholdSignMachineCertClient`, then sends the produced signature
/// + signed `MachineCert` to `POST /bootstrap/accept-household/confirm`.
public struct BootstrapAcceptHouseholdResponse: Sendable, Equatable {
    public let version: UInt64
    public let machineId: String
    public let machinePublicKey: Data
    /// Canonical CBOR bytes the iPhone hands to the household-signing engine.
    /// Sign these bytes (raw, not length-prefixed) under `hh_priv` to produce
    /// the `challengeSig` field on the confirm request.
    public let joinChallenge: Data
    public let challengeSigRequired: Bool

    public init(
        version: UInt64,
        machineId: String,
        machinePublicKey: Data,
        joinChallenge: Data,
        challengeSigRequired: Bool
    ) {
        self.version = version
        self.machineId = machineId
        self.machinePublicKey = machinePublicKey
        self.joinChallenge = joinChallenge
        self.challengeSigRequired = challengeSigRequired
    }
}

/// Client for `POST /bootstrap/accept-household` on a *fresh* engine
/// (Uninitialized or ReadyForNaming). Mobile-first add-Mac flow: the
/// iPhone tells the fresh engine "you're joining household X" and gets
/// a join challenge back; signing is delegated to an existing member
/// engine because the iPhone does not hold `hh_priv` locally.
public struct BootstrapAcceptHouseholdClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/accept-household"

    private static let requiredKeys: Set<String> = [
        "v", "m_id", "m_pub", "join_challenge", "challenge_sig_required",
    ]
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

    /// Calls `POST /bootstrap/accept-household`.
    /// - Parameters:
    ///   - householdId: Existing household id (the iPhone is already a member).
    ///   - householdPublicKey: 33-byte SEC1 compressed P-256 household public key.
    ///   - householdName: 1–32 UTF-8 chars; no control characters.
    ///   - invitationToken: 32-byte one-time token discovered via the fresh
    ///     engine's `_soyeht-setup._tcp.` Bonjour advertisement.
    public func acceptHousehold(
        householdId: String,
        householdPublicKey: Data,
        householdName: String,
        invitationToken: SetupInvitationToken
    ) async throws -> BootstrapAcceptHouseholdResponse {
        // Pre-flight handshake: refuse engines older than
        // `EngineCompat.minSupportedEngineVersion` with a clear message
        // before the main POST. See `docs/engine-protocol-version.md`.
        try await EngineCompat.assertCompatible(
            via: BootstrapStatusClient(baseURL: baseURL, transport: perform)
        )

        let body = Self.encodeRequest(
            householdId: householdId,
            householdPublicKey: householdPublicKey,
            householdName: householdName,
            invitationToken: invitationToken
        )
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let data = try await BootstrapWire.send(
            method: "POST", url: url, body: body, authorization: nil, perform: perform
        )
        return try Self.decode(data)
    }

    // MARK: - Encode

    static func encodeRequest(
        householdId: String,
        householdPublicKey: Data,
        householdName: String,
        invitationToken: SetupInvitationToken
    ) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "hh_id": .text(householdId),
            "hh_pub": .bytes(householdPublicKey),
            "hh_name": .text(householdName),
            "invitation_token": .bytes(invitationToken.bytes),
        ]))
    }

    // MARK: - Decode

    private static func decode(_ data: Data) throws -> BootstrapAcceptHouseholdResponse {
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
              case .text(let mId) = map["m_id"],
              case .bytes(let mPub) = map["m_pub"],
              case .bytes(let challenge) = map["join_challenge"],
              case .bool(let sigRequired) = map["challenge_sig_required"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard mPub.count == 33 else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return BootstrapAcceptHouseholdResponse(
            version: 1,
            machineId: mId,
            machinePublicKey: mPub,
            joinChallenge: challenge,
            challengeSigRequired: sigRequired
        )
    }
}
