import Foundation

/// Platform identifier embedded in a MachineCert. Matches the engine-side
/// enum exactly (see `specs/004-onboarding/contracts/sign-machine-cert.md`).
public enum HouseholdMachinePlatform: String, Sendable, Equatable {
    case macos
    case linuxNix = "linux-nix"
    case linuxOther = "linux-other"
}

/// Inputs the iPhone gathers about the fresh machine (Mac being added)
/// before asking the existing member engine to sign a MachineCert.
public struct HouseholdSignMachineCertSubject: Sendable, Equatable {
    public let machineId: String
    public let machinePublicKey: Data
    public let hostname: String
    public let platform: HouseholdMachinePlatform

    public init(
        machineId: String,
        machinePublicKey: Data,
        hostname: String,
        platform: HouseholdMachinePlatform
    ) {
        self.machineId = machineId
        self.machinePublicKey = machinePublicKey
        self.hostname = hostname
        self.platform = platform
    }
}

/// Response from `POST /api/v1/household/sign-machine-cert`. The iPhone
/// forwards `machineCert` + `challengeSignature` to the fresh engine's
/// `/bootstrap/accept-household/confirm` endpoint.
public struct HouseholdSignMachineCertResponse: Sendable, Equatable {
    public let version: UInt64
    /// Canonical CBOR of the signed MachineCert (opaque to the iPhone).
    public let machineCert: Data
    /// 64-byte raw r||s P-256 signature over the original
    /// `joinChallenge` bytes returned by accept-household prepare.
    public let challengeSignature: Data
    public let machineId: String
    /// Server-side timestamp the engine wrote into the issued cert.
    public let joinedAt: UInt64

    public init(
        version: UInt64,
        machineCert: Data,
        challengeSignature: Data,
        machineId: String,
        joinedAt: UInt64
    ) {
        self.version = version
        self.machineCert = machineCert
        self.challengeSignature = challengeSignature
        self.machineId = machineId
        self.joinedAt = joinedAt
    }
}

/// Client for `POST /api/v1/household/sign-machine-cert`. Called by the
/// iPhone (as proxy) against an existing member engine that still holds
/// `hh_priv` (the founder of the household — Linux in the US-G scenario).
/// Authenticated via Soyeht-PoP v1 from the iPhone's owner identity.
public struct HouseholdSignMachineCertClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/household/sign-machine-cert"

    private static let requiredKeys: Set<String> = [
        "v", "machine_cert", "challenge_signature", "m_id", "joined_at",
    ]
    private static let knownKeys: Set<String> = requiredKeys

    private let baseURL: URL
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        popSigner: HouseholdPoPSigner,
        transport: @escaping TransportPerform = { req in try await BootstrapInitializeClient.defaultSession.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.popSigner = popSigner
        self.perform = transport
    }

    /// - Parameters:
    ///   - subject: Identity of the new machine being signed for.
    ///   - challenge: The `joinChallenge` bytes returned by
    ///     `POST /bootstrap/accept-household` on the fresh engine — these
    ///     are the bytes the engine signs alongside the MachineCert.
    public func signMachineCert(
        subject: HouseholdSignMachineCertSubject,
        challenge: Data
    ) async throws -> HouseholdSignMachineCertResponse {
        guard subject.machinePublicKey.count == 33 else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let body = Self.encodeRequest(subject: subject, challenge: challenge)
        let (url, pathAndQuery) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)

        // PoP signing can throw `HouseholdPoPError.biometryCanceled` etc.;
        // let those propagate verbatim so the orchestrator can show a
        // user-friendly "Cancelled" state instead of a generic network
        // error. Network/protocol failures from the actual HTTP send
        // still surface as `BootstrapError` below.
        let authorization = try popSigner
            .authorization(method: "POST", pathAndQuery: pathAndQuery, body: body)
            .authorizationHeader

        let data = try await BootstrapWire.send(
            method: "POST", url: url, body: body, authorization: authorization, perform: perform
        )
        return try Self.decode(data)
    }

    // MARK: - Encode

    static func encodeRequest(
        subject: HouseholdSignMachineCertSubject,
        challenge: Data
    ) -> Data {
        let subjectMap: [String: HouseholdCBORValue] = [
            "m_id": .text(subject.machineId),
            "m_pub": .bytes(subject.machinePublicKey),
            "hostname": .text(subject.hostname),
            "platform": .text(subject.platform.rawValue),
        ]
        return HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "kind": .text("machine"),
            "subject": .map(subjectMap),
            "challenge": .bytes(challenge),
        ]))
    }

    // MARK: - Decode

    private static func decode(_ data: Data) throws -> HouseholdSignMachineCertResponse {
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
              case .bytes(let cert) = map["machine_cert"],
              case .bytes(let challengeSig) = map["challenge_signature"],
              case .text(let mId) = map["m_id"],
              case .unsigned(let joinedAt) = map["joined_at"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard challengeSig.count == 64 else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return HouseholdSignMachineCertResponse(
            version: 1,
            machineCert: cert,
            challengeSignature: challengeSig,
            machineId: mId,
            joinedAt: joinedAt
        )
    }
}
