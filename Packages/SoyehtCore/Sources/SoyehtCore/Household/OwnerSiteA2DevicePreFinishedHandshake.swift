import CryptoKit
import Foundation

/// Fail-closed errors for the device-side A2 M1/M2/M3 state machine.
///
/// They intentionally do not carry channel secrets, ciphertext, or remote
/// address material. Every failure is terminal for the one local handshake.
enum OwnerSiteA2PreFinishedHandshakeError: Error, Equatable, Sendable {
    case invalidAuthority
    case invalidSigner
    case invalidFrame
    case nonCanonicalFrame
    case unexpectedState
    case invalidNoiseMessage
    case invalidServerHello
    case serverIdentityMismatch
    case staleServerHello
    case invalidServerSignature
    case signingFailed
    case invalidProof
    case handoffUnavailable
}

/// A narrowly-scoped P-256 signer role for an A2 transcript digest.
///
/// A2 requires two separately-bound logical roles: `channel_auth` and
/// `action_pop`. This protocol deliberately does not reuse an owner, guest,
/// relay, or general request-signing capability.
protocol OwnerSiteA2TranscriptDigestSigning: Sendable {
    var ownerSiteA2KeyID: String { get }
    var ownerSiteA2PublicKey: Data { get }

    /// Signs the already-computed 32-byte A2 transcript digest using normal
    /// P-256 ECDSA message semantics and returns a raw 64-byte `r || s` value.
    func signOwnerSiteA2TranscriptDigest(_ digest: Data) throws -> Data
}

/// Synthetic signer for DEBUG-only witnesses. A future production
/// Keychain/Secure Enclave adapter must conform explicitly; it must never
/// make the two A2 signer roles aliases of one another.
#if DEBUG
struct OwnerSiteA2SoftwareTranscriptSigner: OwnerSiteA2TranscriptDigestSigning {
    let ownerSiteA2KeyID: String
    let ownerSiteA2PublicKey: Data
    private let privateKey: P256.Signing.PrivateKey

    init(keyID: String, privateKey: P256.Signing.PrivateKey) throws {
        guard !keyID.isEmpty else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidSigner
        }
        let publicKey = privateKey.publicKey.compressedRepresentation
        do {
            _ = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidSigner
        }
        ownerSiteA2KeyID = keyID
        ownerSiteA2PublicKey = publicKey
        self.privateKey = privateKey
    }

    func signOwnerSiteA2TranscriptDigest(_ digest: Data) throws -> Data {
        guard digest.count == 32 else {
            throw OwnerSiteA2PreFinishedHandshakeError.signingFailed
        }
        do {
            let signature = try privateKey.signature(for: digest).rawRepresentation
            guard signature.count == 64 else {
                throw OwnerSiteA2PreFinishedHandshakeError.signingFailed
            }
            return signature
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            throw error
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.signingFailed
        }
    }
}
#endif

/// A sealed, already-validated local authority snapshot for device A2.
///
/// There is intentionally no production constructor in this slice. The sole
/// construction path is a DEBUG synthetic factory used by tests. A later,
/// separately-reviewed slice may add a factory backed by a signed and fresh
/// roster/binding snapshot. Until then production cannot start M1, which is
/// the desired fail-closed boundary.
struct OwnerSiteA2ValidatedAuthority: Sendable {
    fileprivate let householdID: String
    fileprivate let householdPublicKey: Data
    fileprivate let networkID: String
    fileprivate let route: String
    fileprivate let resource: String
    fileprivate let intentMethod: String
    fileprivate let intentTarget: String
    fileprivate let intentBodyHash: Data
    fileprivate let claimedBindingID: Data
    fileprivate let bindingDigest: Data
    fileprivate let participantNpub: String
    fileprivate let channelAuthKeyID: String
    fileprivate let channelAuthPublicKey: Data
    fileprivate let actionPopKeyID: String
    fileprivate let actionPopPublicKey: Data
    fileprivate let expectedEngineMachineCertificate: Data
    fileprivate let expectedEngineMachinePublicKey: Data
    fileprivate let expectedEngineKeyID: String
    fileprivate let authzEpoch: UInt64
    fileprivate let rosterDigest: Data
    fileprivate let freshUntilUnixSeconds: UInt64
    fileprivate let engineMachineRevoked: Bool

    private init(
        householdID: String,
        householdPublicKey: Data,
        networkID: String,
        route: String,
        resource: String,
        intentMethod: String,
        intentTarget: String,
        intentBodyHash: Data,
        claimedBindingID: Data,
        bindingDigest: Data,
        participantNpub: String,
        channelAuthKeyID: String,
        channelAuthPublicKey: Data,
        actionPopKeyID: String,
        actionPopPublicKey: Data,
        expectedEngineMachineCertificate: Data,
        expectedEngineMachinePublicKey: Data,
        expectedEngineKeyID: String,
        authzEpoch: UInt64,
        rosterDigest: Data,
        freshUntilUnixSeconds: UInt64,
        engineMachineRevoked: Bool
    ) throws {
        guard !householdID.isEmpty,
              !networkID.isEmpty,
              !route.isEmpty,
              !resource.isEmpty,
              !intentMethod.isEmpty,
              intentTarget == route,
              intentBodyHash.count == 32,
              claimedBindingID.count == 32,
              bindingDigest.count == 32,
              !participantNpub.isEmpty,
              !channelAuthKeyID.isEmpty,
              !actionPopKeyID.isEmpty,
              channelAuthKeyID != actionPopKeyID,
              !expectedEngineKeyID.isEmpty,
              authzEpoch > 0,
              rosterDigest.count == 32,
              freshUntilUnixSeconds > 0
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidAuthority
        }

        do {
            _ = try P256.Signing.PublicKey(compressedRepresentation: householdPublicKey)
            _ = try P256.Signing.PublicKey(compressedRepresentation: channelAuthPublicKey)
            _ = try P256.Signing.PublicKey(compressedRepresentation: actionPopPublicKey)
            _ = try P256.Signing.PublicKey(compressedRepresentation: expectedEngineMachinePublicKey)
            let derivedHouseholdID = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)
            guard channelAuthPublicKey != actionPopPublicKey,
                  householdID == derivedHouseholdID
            else {
                throw OwnerSiteA2PreFinishedHandshakeError.invalidAuthority
            }

            let certificate = try MachineCert(cbor: expectedEngineMachineCertificate)
            guard certificate.householdId == householdID,
                  certificate.machinePublicKey == expectedEngineMachinePublicKey
            else {
                throw OwnerSiteA2PreFinishedHandshakeError.invalidAuthority
            }
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            throw error
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidAuthority
        }

        self.householdID = householdID
        self.householdPublicKey = householdPublicKey
        self.networkID = networkID
        self.route = route
        self.resource = resource
        self.intentMethod = intentMethod
        self.intentTarget = intentTarget
        self.intentBodyHash = intentBodyHash
        self.claimedBindingID = claimedBindingID
        self.bindingDigest = bindingDigest
        self.participantNpub = participantNpub
        self.channelAuthKeyID = channelAuthKeyID
        self.channelAuthPublicKey = channelAuthPublicKey
        self.actionPopKeyID = actionPopKeyID
        self.actionPopPublicKey = actionPopPublicKey
        self.expectedEngineMachineCertificate = expectedEngineMachineCertificate
        self.expectedEngineMachinePublicKey = expectedEngineMachinePublicKey
        self.expectedEngineKeyID = expectedEngineKeyID
        self.authzEpoch = authzEpoch
        self.rosterDigest = rosterDigest
        self.freshUntilUnixSeconds = freshUntilUnixSeconds
        self.engineMachineRevoked = engineMachineRevoked
    }

#if DEBUG
    /// Test-only capability. It is unavailable in production builds until a
    /// future signed roster/binding authority factory is reviewed.
    static func syntheticTestOnly(
        householdID: String,
        householdPublicKey: Data,
        networkID: String,
        route: String,
        resource: String,
        intentMethod: String,
        intentTarget: String,
        intentBodyHash: Data,
        claimedBindingID: Data,
        bindingDigest: Data,
        participantNpub: String,
        channelAuthKeyID: String,
        channelAuthPublicKey: Data,
        actionPopKeyID: String,
        actionPopPublicKey: Data,
        expectedEngineMachineCertificate: Data,
        expectedEngineMachinePublicKey: Data,
        expectedEngineKeyID: String,
        authzEpoch: UInt64,
        rosterDigest: Data,
        freshUntilUnixSeconds: UInt64,
        engineMachineRevoked: Bool = false
    ) throws -> OwnerSiteA2ValidatedAuthority {
        try OwnerSiteA2ValidatedAuthority(
            householdID: householdID,
            householdPublicKey: householdPublicKey,
            networkID: networkID,
            route: route,
            resource: resource,
            intentMethod: intentMethod,
            intentTarget: intentTarget,
            intentBodyHash: intentBodyHash,
            claimedBindingID: claimedBindingID,
            bindingDigest: bindingDigest,
            participantNpub: participantNpub,
            channelAuthKeyID: channelAuthKeyID,
            channelAuthPublicKey: channelAuthPublicKey,
            actionPopKeyID: actionPopKeyID,
            actionPopPublicKey: actionPopPublicKey,
            expectedEngineMachineCertificate: expectedEngineMachineCertificate,
            expectedEngineMachinePublicKey: expectedEngineMachinePublicKey,
            expectedEngineKeyID: expectedEngineKeyID,
            authzEpoch: authzEpoch,
            rosterDigest: rosterDigest,
            freshUntilUnixSeconds: freshUntilUnixSeconds,
            engineMachineRevoked: engineMachineRevoked
        )
    }
#endif
}

/// Canonical request intent nested in C1 and bound into the owner-action PoP.
struct OwnerSiteA2CanonicalIntent: Equatable, Sendable {
    let method: String
    let target: String
    let bodyHash: Data

    init(method: String, target: String, bodyHash: Data) throws {
        guard !method.isEmpty, !target.isEmpty, bodyHash.count == 32 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidAuthority
        }
        self.method = method
        self.target = target
        self.bodyHash = bodyHash
    }

    func canonicalCBOR() -> Data {
        HouseholdCBOR.encode(.map([
            "body_hash": .bytes(bodyHash),
            "method": .text(method),
            "target": .text(target),
        ]))
    }

    static func decodeCanonical(_ bytes: Data) throws -> OwnerSiteA2CanonicalIntent {
        let map = try OwnerSiteA2PreFinishedCBOR.decodeCanonicalMap(bytes)
        try OwnerSiteA2PreFinishedCBOR.requireExactKeys(map, ["body_hash", "method", "target"])
        return try OwnerSiteA2CanonicalIntent(
            method: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "method"),
            target: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "target"),
            bodyHash: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "body_hash", count: 32)
        )
    }
}

/// The M1 plaintext. `device_ephemeral` is intentionally outside this value:
/// it is the XX e token, but C1 binds it separately for T1.
struct OwnerSiteA2ClientHelloCore: Equatable, Sendable {
    let householdID: String
    let networkID: String
    let route: String
    let resource: String
    let intent: OwnerSiteA2CanonicalIntent
    let claimedBindingID: Data

    init(authority: OwnerSiteA2ValidatedAuthority) throws {
        householdID = authority.householdID
        networkID = authority.networkID
        route = authority.route
        resource = authority.resource
        intent = try OwnerSiteA2CanonicalIntent(
            method: authority.intentMethod,
            target: authority.intentTarget,
            bodyHash: authority.intentBodyHash
        )
        claimedBindingID = authority.claimedBindingID
    }

    func canonicalCBOR() -> Data {
        HouseholdCBOR.encode(.map([
            "claimed_binding_id": .bytes(claimedBindingID),
            "domain": .text(OwnerSiteA2TransportProfile.domain),
            "household_id": .text(householdID),
            "intent": .map([
                "body_hash": .bytes(intent.bodyHash),
                "method": .text(intent.method),
                "target": .text(intent.target),
            ]),
            "network_id": .text(networkID),
            "resource": .text(resource),
            "route": .text(route),
            "version": .unsigned(OwnerSiteA2TransportProfile.version),
        ]))
    }

    static func decodeCanonical(_ bytes: Data) throws -> OwnerSiteA2ClientHelloCore {
        let map = try OwnerSiteA2PreFinishedCBOR.decodeCanonicalMap(bytes)
        try OwnerSiteA2PreFinishedCBOR.requireExactKeys(
            map,
            ["claimed_binding_id", "domain", "household_id", "intent", "network_id", "resource", "route", "version"]
        )
        guard try OwnerSiteA2PreFinishedCBOR.requiredText(map, "domain") == OwnerSiteA2TransportProfile.domain,
              try OwnerSiteA2PreFinishedCBOR.requiredUnsigned(map, "version") == OwnerSiteA2TransportProfile.version
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        let intentValue = try OwnerSiteA2PreFinishedCBOR.requiredValue(map, "intent")
        guard case let .map(intentMap) = intentValue else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        let intentBytes = HouseholdCBOR.encode(.map(intentMap))
        return OwnerSiteA2ClientHelloCore(
            householdID: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "household_id"),
            networkID: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "network_id"),
            route: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "route"),
            resource: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "resource"),
            intent: try OwnerSiteA2CanonicalIntent.decodeCanonical(intentBytes),
            claimedBindingID: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "claimed_binding_id", count: 32)
        )
    }

    private init(
        householdID: String,
        networkID: String,
        route: String,
        resource: String,
        intent: OwnerSiteA2CanonicalIntent,
        claimedBindingID: Data
    ) {
        self.householdID = householdID
        self.networkID = networkID
        self.route = route
        self.resource = resource
        self.intent = intent
        self.claimedBindingID = claimedBindingID
    }
}

/// C1's canonical form enters T1 as one bstr. It is never substituted with
/// the outer frame or a reassembled plaintext.
struct OwnerSiteA2ClientHello: Equatable, Sendable {
    let core: OwnerSiteA2ClientHelloCore
    let deviceEphemeral: Data

    init(core: OwnerSiteA2ClientHelloCore, deviceEphemeral: Data) throws {
        guard deviceEphemeral.count == 32 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
        self.core = core
        self.deviceEphemeral = deviceEphemeral
    }

    func canonicalCBOR() -> Data {
        HouseholdCBOR.encode(.map([
            "core": .map([
                "claimed_binding_id": .bytes(core.claimedBindingID),
                "domain": .text(OwnerSiteA2TransportProfile.domain),
                "household_id": .text(core.householdID),
                "intent": .map([
                    "body_hash": .bytes(core.intent.bodyHash),
                    "method": .text(core.intent.method),
                    "target": .text(core.intent.target),
                ]),
                "network_id": .text(core.networkID),
                "resource": .text(core.resource),
                "route": .text(core.route),
                "version": .unsigned(OwnerSiteA2TransportProfile.version),
            ]),
            "device_ephemeral": .bytes(deviceEphemeral),
        ]))
    }

    static func decodeCanonical(_ bytes: Data) throws -> OwnerSiteA2ClientHello {
        let map = try OwnerSiteA2PreFinishedCBOR.decodeCanonicalMap(bytes)
        try OwnerSiteA2PreFinishedCBOR.requireExactKeys(map, ["core", "device_ephemeral"])
        let coreValue = try OwnerSiteA2PreFinishedCBOR.requiredValue(map, "core")
        guard case let .map(coreMap) = coreValue else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return try OwnerSiteA2ClientHello(
            core: OwnerSiteA2ClientHelloCore.decodeCanonical(HouseholdCBOR.encode(.map(coreMap))),
            deviceEphemeral: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "device_ephemeral", count: 32)
        )
    }
}

/// The M2 plaintext after successful Noise authentication.
struct OwnerSiteA2ServerHello: Equatable, Sendable {
    let engineMachineCertificate: Data
    let engineKeyID: String
    let channelID: Data
    let channelEpoch: UInt64
    let challengeID: Data
    let challengeSecret: Data
    let authzEpoch: UInt64
    let rosterDigest: Data
    let freshUntilUnixSeconds: UInt64
    let engineSignature: Data

    init(
        engineMachineCertificate: Data,
        engineKeyID: String,
        channelID: Data,
        channelEpoch: UInt64,
        challengeID: Data,
        challengeSecret: Data,
        authzEpoch: UInt64,
        rosterDigest: Data,
        freshUntilUnixSeconds: UInt64,
        engineSignature: Data
    ) throws {
        guard !engineMachineCertificate.isEmpty,
              !engineKeyID.isEmpty,
              channelID.count == 32,
              channelEpoch > 0,
              challengeID.count == 32,
              challengeSecret.count == 32,
              authzEpoch > 0,
              rosterDigest.count == 32,
              freshUntilUnixSeconds > 0,
              engineSignature.count == 64
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidServerHello
        }
        self.engineMachineCertificate = engineMachineCertificate
        self.engineKeyID = engineKeyID
        self.channelID = channelID
        self.channelEpoch = channelEpoch
        self.challengeID = challengeID
        self.challengeSecret = challengeSecret
        self.authzEpoch = authzEpoch
        self.rosterDigest = rosterDigest
        self.freshUntilUnixSeconds = freshUntilUnixSeconds
        self.engineSignature = engineSignature
    }

    func canonicalCBOR() -> Data {
        HouseholdCBOR.encode(.map([
            "authz_epoch": .unsigned(authzEpoch),
            "challenge_id": .bytes(challengeID),
            "challenge_secret": .bytes(challengeSecret),
            "channel_epoch": .unsigned(channelEpoch),
            "channel_id": .bytes(channelID),
            "engine_key_id": .text(engineKeyID),
            "engine_machine_certificate": .bytes(engineMachineCertificate),
            "engine_signature": .bytes(engineSignature),
            "fresh_until": .unsigned(freshUntilUnixSeconds),
            "roster_digest": .bytes(rosterDigest),
        ]))
    }

    static func decodeCanonical(_ bytes: Data) throws -> OwnerSiteA2ServerHello {
        let map = try OwnerSiteA2PreFinishedCBOR.decodeCanonicalMap(bytes)
        try OwnerSiteA2PreFinishedCBOR.requireExactKeys(
            map,
            [
                "authz_epoch", "challenge_id", "challenge_secret", "channel_epoch", "channel_id",
                "engine_key_id", "engine_machine_certificate", "engine_signature", "fresh_until", "roster_digest",
            ]
        )
        return try OwnerSiteA2ServerHello(
            engineMachineCertificate: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "engine_machine_certificate"),
            engineKeyID: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "engine_key_id"),
            channelID: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "channel_id", count: 32),
            channelEpoch: try OwnerSiteA2PreFinishedCBOR.requiredUnsigned(map, "channel_epoch", nonzero: true),
            challengeID: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "challenge_id", count: 32),
            challengeSecret: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "challenge_secret", count: 32),
            authzEpoch: try OwnerSiteA2PreFinishedCBOR.requiredUnsigned(map, "authz_epoch", nonzero: true),
            rosterDigest: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "roster_digest", count: 32),
            freshUntilUnixSeconds: try OwnerSiteA2PreFinishedCBOR.requiredUnsigned(map, "fresh_until", nonzero: true),
            engineSignature: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "engine_signature", count: 64)
        )
    }
}

/// The M3 plaintext sealed by the final XX message.
struct OwnerSiteA2ClientProof: Equatable, Sendable {
    let bindingID: Data
    let bindingDigest: Data
    let participantNpub: String
    let channelAuthKeyID: String
    let actionPopKeyID: String
    let deviceSignature: Data
    let actionPop: Data

    init(
        bindingID: Data,
        bindingDigest: Data,
        participantNpub: String,
        channelAuthKeyID: String,
        actionPopKeyID: String,
        deviceSignature: Data,
        actionPop: Data
    ) throws {
        guard bindingID.count == 32,
              bindingDigest.count == 32,
              !participantNpub.isEmpty,
              !channelAuthKeyID.isEmpty,
              !actionPopKeyID.isEmpty,
              channelAuthKeyID != actionPopKeyID,
              deviceSignature.count == 64,
              actionPop.count == 64
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidProof
        }
        self.bindingID = bindingID
        self.bindingDigest = bindingDigest
        self.participantNpub = participantNpub
        self.channelAuthKeyID = channelAuthKeyID
        self.actionPopKeyID = actionPopKeyID
        self.deviceSignature = deviceSignature
        self.actionPop = actionPop
    }

    func canonicalCBOR() -> Data {
        HouseholdCBOR.encode(.map([
            "action_pop": .bytes(actionPop),
            "action_pop_key_id": .text(actionPopKeyID),
            "binding_digest": .bytes(bindingDigest),
            "binding_id": .bytes(bindingID),
            "channel_auth_key_id": .text(channelAuthKeyID),
            "device_signature": .bytes(deviceSignature),
            "participant_npub": .text(participantNpub),
        ]))
    }

    static func decodeCanonical(_ bytes: Data) throws -> OwnerSiteA2ClientProof {
        let map = try OwnerSiteA2PreFinishedCBOR.decodeCanonicalMap(bytes)
        try OwnerSiteA2PreFinishedCBOR.requireExactKeys(
            map,
            ["action_pop", "action_pop_key_id", "binding_digest", "binding_id", "channel_auth_key_id", "device_signature", "participant_npub"]
        )
        return try OwnerSiteA2ClientProof(
            bindingID: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "binding_id", count: 32),
            bindingDigest: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "binding_digest", count: 32),
            participantNpub: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "participant_npub"),
            channelAuthKeyID: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "channel_auth_key_id"),
            actionPopKeyID: try OwnerSiteA2PreFinishedCBOR.requiredText(map, "action_pop_key_id"),
            deviceSignature: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "device_signature", count: 64),
            actionPop: try OwnerSiteA2PreFinishedCBOR.requiredBytes(map, "action_pop", count: 64)
        )
    }
}

/// Exact transcript hashes required by A2-R1. Every input is one element of a
/// fixed-arity canonical CBOR array; no variable data is byte-concatenated.
enum OwnerSiteA2PreFinishedTranscript {
    static func serverAuthT1(
        clientHello: OwnerSiteA2ClientHello,
        engineEphemeral: Data,
        engineStatic: Data,
        serverHello: OwnerSiteA2ServerHello
    ) throws -> Data {
        guard engineEphemeral.count == 32, engineStatic.count == 32 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidServerHello
        }
        let certificateDigest = Data(SHA256.hash(data: serverHello.engineMachineCertificate))
        return hash([
            .text(OwnerSiteA2TransportProfile.domain),
            .text("server-auth"),
            .bytes(clientHello.canonicalCBOR()),
            .bytes(engineEphemeral),
            .bytes(engineStatic),
            .bytes(certificateDigest),
            .text(serverHello.engineKeyID),
            .bytes(serverHello.channelID),
            .unsigned(serverHello.channelEpoch),
            .bytes(serverHello.challengeID),
            .bytes(serverHello.challengeSecret),
            .unsigned(serverHello.authzEpoch),
            .bytes(serverHello.rosterDigest),
            .unsigned(serverHello.freshUntilUnixSeconds),
        ])
    }

    static func popBindingPre(t1: Data, deviceStatic: Data) throws -> Data {
        guard t1.count == 32, deviceStatic.count == 32 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidProof
        }
        return hash([
            .text(OwnerSiteA2TransportProfile.domain),
            .text("pop-binding"),
            .bytes(t1),
            .bytes(deviceStatic),
        ])
    }

    static func deviceAuth(
        preBinding: Data,
        authority: OwnerSiteA2ValidatedAuthority
    ) throws -> Data {
        guard preBinding.count == 32 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidProof
        }
        return hash([
            .text(OwnerSiteA2TransportProfile.domain),
            .text("D-auth"),
            .bytes(preBinding),
            .bytes(authority.claimedBindingID),
            .bytes(authority.bindingDigest),
            .text(authority.participantNpub),
            .text(authority.channelAuthKeyID),
        ])
    }

    static func ownerAction(
        preBinding: Data,
        authority: OwnerSiteA2ValidatedAuthority,
        serverHello: OwnerSiteA2ServerHello,
        clientHelloCore: OwnerSiteA2ClientHelloCore
    ) throws -> Data {
        guard preBinding.count == 32 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidProof
        }
        return hash([
            .text(OwnerSiteA2TransportProfile.domain),
            .text("owner-action"),
            .bytes(preBinding),
            .bytes(serverHello.channelID),
            .unsigned(serverHello.channelEpoch),
            .bytes(serverHello.challengeID),
            .bytes(serverHello.challengeSecret),
            .text(clientHelloCore.householdID),
            .text(clientHelloCore.networkID),
            .text(serverHello.engineKeyID),
            .bytes(authority.claimedBindingID),
            .bytes(authority.bindingDigest),
            .text(authority.participantNpub),
            .text(clientHelloCore.route),
            .text(clientHelloCore.resource),
            .bytes(clientHelloCore.intent.canonicalCBOR()),
            .unsigned(serverHello.authzEpoch),
            .bytes(serverHello.rosterDigest),
            .unsigned(serverHello.freshUntilUnixSeconds),
        ])
    }

    static func channelBinding(
        handshakeHash: Data,
        channelID: Data,
        channelEpoch: UInt64
    ) throws -> Data {
        guard handshakeHash.count == 32, channelID.count == 32, channelEpoch > 0 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidProof
        }
        return hash([
            .text(OwnerSiteA2TransportProfile.domain),
            .text("channel-binding"),
            .unsigned(OwnerSiteA2TransportProfile.version),
            .text(OwnerSiteA2TransportProfile.recordVersion),
            .text(OwnerSiteA2TransportProfile.protocolName),
            .bytes(handshakeHash),
            .bytes(channelID),
            .unsigned(channelEpoch),
        ])
    }

    private static func hash(_ fields: [HouseholdCBORValue]) -> Data {
        Data(SHA256.hash(data: HouseholdCBOR.encode(.array(fields))))
    }
}

/// Stateful, device-initiator implementation of the fixed A2-R1 XX-shaped
/// profile. It uses CryptoKit's vetted X25519 and ChaChaPoly primitives; this
/// type supplies only the reviewed Noise framing and exact transcript state.
private struct OwnerSiteA2NoiseXXInitiatorState {
    private enum Phase {
        case fresh
        case m1Emitted
        case m2Accepted
        case m3Emitted
        case closed
    }

    private var symmetric: OwnerSiteA2NoiseSymmetricState?
    private var deviceEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var deviceStatic: Curve25519.KeyAgreement.PrivateKey?
    private var engineEphemeral: Data?
    private var phase: Phase = .fresh

    init() {
        symmetric = OwnerSiteA2NoiseSymmetricState()
        deviceEphemeral = Curve25519.KeyAgreement.PrivateKey()
        deviceStatic = Curve25519.KeyAgreement.PrivateKey()
    }

#if DEBUG
    /// KAT-only deterministic construction from the frozen synthetic X25519
    /// inputs. It is not an authority source and never ships as a caller.
    init(syntheticDeviceStatic: Data, syntheticDeviceEphemeral: Data) throws {
        do {
            symmetric = OwnerSiteA2NoiseSymmetricState()
            deviceStatic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: syntheticDeviceStatic)
            deviceEphemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: syntheticDeviceEphemeral)
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }
#endif

    mutating func emitM1(_ payload: Data) throws -> Data {
        guard phase == .fresh,
              !payload.isEmpty,
              payload.count <= OwnerSiteA2PreFinishedCBOR.maximumFrameBytes,
              let deviceEphemeral,
              var symmetric
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.unexpectedState
        }

        do {
            let publicKey = deviceEphemeral.publicKey.rawRepresentation
            symmetric.mixHash(publicKey)
            let encryptedPayload = try symmetric.encryptAndHash(payload)
            self.symmetric = symmetric
            phase = .m1Emitted
            return publicKey + encryptedPayload
        } catch {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }

    mutating func acceptM2(_ wire: Data) throws -> OwnerSiteA2NoiseM2Result {
        guard phase == .m1Emitted,
              wire.count >= 96,
              wire.count <= OwnerSiteA2PreFinishedCBOR.maximumFrameBytes,
              let deviceEphemeral,
              var symmetric
        else {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }

        do {
            let engineEphemeral = Data(wire.prefix(32))
            let engineEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: engineEphemeral)
            symmetric.mixHash(engineEphemeral)
            symmetric.mixKey(try sharedSecret(local: deviceEphemeral, remote: engineEphemeralKey))

            let encryptedStatic = Data(wire.dropFirst(32).prefix(48))
            let engineStatic = try symmetric.decryptAndHash(encryptedStatic)
            let engineStaticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: engineStatic)
            symmetric.mixKey(try sharedSecret(local: deviceEphemeral, remote: engineStaticKey))

            let encryptedPayload = Data(wire.dropFirst(80))
            let payload = try symmetric.decryptAndHash(encryptedPayload)
            guard !payload.isEmpty else {
                throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
            }

            self.symmetric = symmetric
            self.engineEphemeral = engineEphemeral
            phase = .m2Accepted
            return OwnerSiteA2NoiseM2Result(
                payload: payload,
                engineEphemeral: engineEphemeral,
                engineStatic: engineStatic,
                deviceStatic: try deviceStaticPublicKey()
            )
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            close()
            throw error
        } catch {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }

    mutating func emitM3(_ payload: Data) throws -> OwnerSiteA2NoiseM3Result {
        guard phase == .m2Accepted,
              !payload.isEmpty,
              payload.count <= OwnerSiteA2PreFinishedCBOR.maximumFrameBytes,
              let deviceStatic,
              let engineEphemeral,
              let engineEphemeralKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: engineEphemeral),
              var symmetric
        else {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.unexpectedState
        }

        do {
            let encryptedStatic = try symmetric.encryptAndHash(deviceStatic.publicKey.rawRepresentation)
            symmetric.mixKey(try sharedSecret(local: deviceStatic, remote: engineEphemeralKey))
            let encryptedPayload = try symmetric.encryptAndHash(payload)
            let result = OwnerSiteA2NoiseM3Result(
                wire: encryptedStatic + encryptedPayload,
                handshakeHash: symmetric.handshakeHash,
                chainingKey: try symmetric.chainingKeyBytes()
            )
            self.symmetric = symmetric
            phase = .m3Emitted
            return result
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            close()
            throw error
        } catch {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }

    mutating func close() {
        symmetric?.close()
        symmetric = nil
        deviceEphemeral = nil
        deviceStatic = nil
        engineEphemeral = nil
        phase = .closed
    }

    private func deviceStaticPublicKey() throws -> Data {
        guard let deviceStatic else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
        return deviceStatic.publicKey.rawRepresentation
    }

    private func sharedSecret(
        local: Curve25519.KeyAgreement.PrivateKey,
        remote: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        do {
            let shared = try local.sharedSecretFromKeyAgreement(with: remote)
            return shared.withUnsafeBytes { Data($0) }
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }
}

private struct OwnerSiteA2NoiseM2Result {
    let payload: Data
    let engineEphemeral: Data
    let engineStatic: Data
    let deviceStatic: Data
}

private struct OwnerSiteA2NoiseM3Result {
    let wire: Data
    let handshakeHash: Data
    fileprivate let chainingKey: Data
}

#if DEBUG
/// Deterministic, test-only witness for the file-private Noise state. It
/// exposes only the frozen KAT's public wires and H_final—never a chaining
/// key, Split key, authority capability, or Finished transport.
enum OwnerSiteA2PreFinishedNoiseKAT {
    static func reproduce(
        deviceStatic: Data,
        deviceEphemeral: Data,
        m1Payload: Data,
        m2Wire: Data,
        m3Payload: Data
    ) throws -> (m1Wire: Data, m2Payload: Data, m3Wire: Data, handshakeHash: Data) {
        var initiator = try OwnerSiteA2NoiseXXInitiatorState(
            syntheticDeviceStatic: deviceStatic,
            syntheticDeviceEphemeral: deviceEphemeral
        )
        let m1Wire = try initiator.emitM1(m1Payload)
        let m2 = try initiator.acceptM2(m2Wire)
        let m3 = try initiator.emitM3(m3Payload)
        return (
            m1Wire: m1Wire,
            m2Payload: m2.payload,
            m3Wire: m3.wire,
            handshakeHash: m3.handshakeHash
        )
    }
}
#endif

private struct OwnerSiteA2NoiseSymmetricState {
    private var chainingKey: SymmetricKey?
    private(set) var handshakeHash: Data
    private var cipher = OwnerSiteA2NoiseCipherState()

    init() {
        let protocolName = Data(OwnerSiteA2TransportProfile.protocolName.utf8)
        let initialHash: Data
        if protocolName.count <= 32 {
            initialHash = protocolName + Data(repeating: 0, count: 32 - protocolName.count)
        } else {
            initialHash = Data(SHA256.hash(data: protocolName))
        }
        handshakeHash = initialHash
        chainingKey = SymmetricKey(data: initialHash)
        mixHash(OwnerSiteA2PreFinishedCBOR.noisePrologue)
    }

    mutating func mixHash(_ bytes: Data) {
        handshakeHash = Data(SHA256.hash(data: handshakeHash + bytes))
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        guard let chainingKey else { return }
        let temporaryKey = Self.hmac(key: chainingKey, message: inputKeyMaterial)
        let temporarySymmetricKey = SymmetricKey(data: temporaryKey)
        let nextChainingKey = Self.hmac(key: temporarySymmetricKey, message: Data([1]))
        let cipherKey = Self.hmac(
            key: temporarySymmetricKey,
            message: nextChainingKey + Data([2])
        )
        self.chainingKey = SymmetricKey(data: nextChainingKey)
        cipher.setKey(SymmetricKey(data: cipherKey))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encryptAndIncrement(plaintext, authenticating: handshakeHash)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decryptAndIncrement(ciphertext, authenticating: handshakeHash)
        mixHash(ciphertext)
        return plaintext
    }

    func chainingKeyBytes() throws -> Data {
        guard let chainingKey else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
        return chainingKey.withUnsafeBytes { Data($0) }
    }

    mutating func close() {
        chainingKey = nil
        cipher.close()
        handshakeHash = Data(repeating: 0, count: handshakeHash.count)
    }

    private static func hmac(key: SymmetricKey, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }
}

private struct OwnerSiteA2NoiseCipherState {
    private var key: SymmetricKey?
    private var nextNonce: UInt64 = 0

    mutating func setKey(_ key: SymmetricKey) {
        self.key = key
        nextNonce = 0
    }

    mutating func encryptAndIncrement(_ plaintext: Data, authenticating ad: Data) throws -> Data {
        guard let key else { return plaintext }
        do {
            let nonce = try reserveNonce()
            let sealed = try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: try Self.nonce(for: nonce),
                authenticating: ad
            )
            return sealed.ciphertext + sealed.tag
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }

    mutating func decryptAndIncrement(_ ciphertextAndTag: Data, authenticating ad: Data) throws -> Data {
        guard let key else { return ciphertextAndTag }
        guard ciphertextAndTag.count >= OwnerSiteA2TransportProfile.authenticationTagBytes else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
        do {
            let nonce = try reserveNonce()
            let sealed = try ChaChaPoly.SealedBox(
                nonce: try Self.nonce(for: nonce),
                ciphertext: ciphertextAndTag.dropLast(OwnerSiteA2TransportProfile.authenticationTagBytes),
                tag: ciphertextAndTag.suffix(OwnerSiteA2TransportProfile.authenticationTagBytes)
            )
            return try ChaChaPoly.open(sealed, using: key, authenticating: ad)
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            throw error
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }

    mutating func close() {
        key = nil
        nextNonce = 0
    }

    private mutating func reserveNonce() throws -> UInt64 {
        guard nextNonce < UInt64.max else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
        defer { nextNonce += 1 }
        return nextNonce
    }

    private static func nonce(for sequence: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        var littleEndian = sequence.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        do {
            return try ChaChaPoly.Nonce(data: bytes)
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }
}

/// Device-role M1/M2/M3 state. It emits only local canonical bytes and can
/// hand off exactly once to the existing S2/C3 actor. It has no carrier,
/// provider, peer, persistence, or data-plane effect surface.
actor OwnerSiteA2DevicePreFinishedHandshake {
    private enum Phase {
        case fresh
        case awaitingM2
        case m3Ready
        case transferred
        case closed
    }

    private var authority: OwnerSiteA2ValidatedAuthority?
    private var channelAuthSigner: (any OwnerSiteA2TranscriptDigestSigning)?
    private var actionPopSigner: (any OwnerSiteA2TranscriptDigestSigning)?
    private var noise: OwnerSiteA2NoiseXXInitiatorState?
    private var clientHello: OwnerSiteA2ClientHello?
    private var finishedTransport: OwnerSiteA2DeviceFinishedTransport?
    private var phase: Phase = .fresh

    init(
        authority: OwnerSiteA2ValidatedAuthority,
        channelAuthSigner: any OwnerSiteA2TranscriptDigestSigning,
        actionPopSigner: any OwnerSiteA2TranscriptDigestSigning
    ) throws {
        guard channelAuthSigner.ownerSiteA2KeyID == authority.channelAuthKeyID,
              channelAuthSigner.ownerSiteA2PublicKey == authority.channelAuthPublicKey,
              actionPopSigner.ownerSiteA2KeyID == authority.actionPopKeyID,
              actionPopSigner.ownerSiteA2PublicKey == authority.actionPopPublicKey
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidSigner
        }
        self.authority = authority
        self.channelAuthSigner = channelAuthSigner
        self.actionPopSigner = actionPopSigner
    }

    /// Emits canonical M1. Each actor owns newly-generated X25519 e_D/s_D and
    /// cannot reset or reuse them for another channel.
    func emitM1() throws -> Data {
        guard phase == .fresh, let authority else {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.unexpectedState
        }
        var localNoise: OwnerSiteA2NoiseXXInitiatorState?
        do {
            let core = try OwnerSiteA2ClientHelloCore(authority: authority)
            var nextNoise = OwnerSiteA2NoiseXXInitiatorState()
            let m1Noise = try nextNoise.emitM1(core.canonicalCBOR())
            localNoise = nextNoise
            let c1 = try OwnerSiteA2ClientHello(
                core: core,
                deviceEphemeral: Data(m1Noise.prefix(32))
            )
            noise = nextNoise
            nextNoise.close()
            localNoise?.close()
            localNoise = nil
            clientHello = c1
            phase = .awaitingM2
            return try OwnerSiteA2PreFinishedCBOR.encodeFrame(kind: 1, noise: m1Noise)
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            // If canonical framing rejects the just-produced M1, clear the
            // transient copy (when it still exists) and the actor state.
            localNoise?.close()
            close()
            throw error
        } catch {
            localNoise?.close()
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }

    /// Authenticates one canonical M2 completely before either device signer
    /// is invoked, then emits canonical M3. A duplicate, malformed, stale,
    /// or unauthenticated M2 closes this actor permanently.
    func acceptM2AndMakeM3(
        _ m2Frame: Data,
        trustedNow: OwnerSiteA2TrustedUTC
    ) throws -> Data {
        guard phase == .awaitingM2,
              var localNoise = noise,
              let authority,
              let clientHello,
              let channelAuthSigner,
              let actionPopSigner
        else {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.unexpectedState
        }

        do {
            let m2Noise = try OwnerSiteA2PreFinishedCBOR.decodeFrame(m2Frame, expectedKind: 2)
            let noiseResult = try localNoise.acceptM2(m2Noise)
            let serverHello = try OwnerSiteA2ServerHello.decodeCanonical(noiseResult.payload)
            let t1 = try validate(
                serverHello: serverHello,
                authority: authority,
                clientHello: clientHello,
                noiseResult: noiseResult,
                trustedNow: trustedNow
            )

            let preBinding = try OwnerSiteA2PreFinishedTranscript.popBindingPre(
                t1: t1,
                deviceStatic: noiseResult.deviceStatic
            )
            let deviceSignature = try checkedSignature(
                signer: channelAuthSigner,
                expectedPublicKey: authority.channelAuthPublicKey,
                digest: try OwnerSiteA2PreFinishedTranscript.deviceAuth(
                    preBinding: preBinding,
                    authority: authority
                )
            )
            let actionPop = try checkedSignature(
                signer: actionPopSigner,
                expectedPublicKey: authority.actionPopPublicKey,
                digest: try OwnerSiteA2PreFinishedTranscript.ownerAction(
                    preBinding: preBinding,
                    authority: authority,
                    serverHello: serverHello,
                    clientHelloCore: clientHello.core
                )
            )
            let proof = try OwnerSiteA2ClientProof(
                bindingID: authority.claimedBindingID,
                bindingDigest: authority.bindingDigest,
                participantNpub: authority.participantNpub,
                channelAuthKeyID: authority.channelAuthKeyID,
                actionPopKeyID: authority.actionPopKeyID,
                deviceSignature: deviceSignature,
                actionPop: actionPop
            )
            let m3Result = try localNoise.emitM3(proof.canonicalCBOR())
            let context = try OwnerSiteA2FinishedContext(
                channelID: serverHello.channelID,
                channelEpoch: serverHello.channelEpoch,
                bindingID: authority.claimedBindingID,
                bindingDigest: authority.bindingDigest,
                authzEpoch: serverHello.authzEpoch,
                rosterDigest: serverHello.rosterDigest,
                freshUntilUnixSeconds: serverHello.freshUntilUnixSeconds
            )
            let localFinished = try OwnerSiteA2DeviceFinishedTransport.fromValidatedHandshake(
                chainingKey: m3Result.chainingKey,
                handshakeHash: m3Result.handshakeHash,
                context: context
            )
            localNoise.close()
            noise?.close()
            noise = nil
            finishedTransport = localFinished
            phase = .m3Ready
            return try OwnerSiteA2PreFinishedCBOR.encodeFrame(kind: 3, noise: m3Result.wire)
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            // `localNoise` has already advanced through M2 by the time an
            // authority, signature, proof, or handoff check can fail. It is
            // a value copy of the stored pre-M2 state, so close it explicitly
            // before clearing the actor's stored state as well.
            localNoise.close()
            close()
            throw error
        } catch {
            // Keep the same key-hygiene guarantee for unexpected CryptoKit or
            // canonical-CBOR failures after the local copy has advanced.
            localNoise.close()
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.invalidNoiseMessage
        }
    }

    /// Moves the only post-M3 state into the existing Finished actor. This is
    /// one-way: callers cannot ask this handshake to mint another transport.
    func takeFinishedTransport() throws -> OwnerSiteA2DeviceFinishedTransport {
        guard phase == .m3Ready, let finishedTransport else {
            close()
            throw OwnerSiteA2PreFinishedHandshakeError.handoffUnavailable
        }
        self.finishedTransport = nil
        authority = nil
        channelAuthSigner = nil
        actionPopSigner = nil
        clientHello = nil
        phase = .transferred
        return finishedTransport
    }

    func close() {
        noise?.close()
        noise = nil
        authority = nil
        channelAuthSigner = nil
        actionPopSigner = nil
        clientHello = nil
        finishedTransport = nil
        phase = .closed
    }

    private func validate(
        serverHello: OwnerSiteA2ServerHello,
        authority: OwnerSiteA2ValidatedAuthority,
        clientHello: OwnerSiteA2ClientHello,
        noiseResult: OwnerSiteA2NoiseM2Result,
        trustedNow: OwnerSiteA2TrustedUTC
    ) throws -> Data {
        guard serverHello.engineMachineCertificate == authority.expectedEngineMachineCertificate,
              serverHello.engineKeyID == authority.expectedEngineKeyID,
              serverHello.authzEpoch == authority.authzEpoch,
              serverHello.rosterDigest == authority.rosterDigest,
              serverHello.freshUntilUnixSeconds == authority.freshUntilUnixSeconds
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.serverIdentityMismatch
        }
        guard serverHello.freshUntilUnixSeconds > trustedNow.unixSeconds else {
            throw OwnerSiteA2PreFinishedHandshakeError.staleServerHello
        }

        let certificate: MachineCert
        do {
            certificate = try MachineCert(cbor: serverHello.engineMachineCertificate)
            try MachineCertValidator.validate(
                cert: certificate,
                expectedHouseholdId: authority.householdID,
                householdPublicKey: authority.householdPublicKey,
                isRevoked: { _ in authority.engineMachineRevoked },
                now: Date(timeIntervalSince1970: TimeInterval(trustedNow.unixSeconds))
            )
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.serverIdentityMismatch
        }
        guard certificate.machinePublicKey == authority.expectedEngineMachinePublicKey else {
            throw OwnerSiteA2PreFinishedHandshakeError.serverIdentityMismatch
        }

        let t1 = try OwnerSiteA2PreFinishedTranscript.serverAuthT1(
            clientHello: clientHello,
            engineEphemeral: noiseResult.engineEphemeral,
            engineStatic: noiseResult.engineStatic,
            serverHello: serverHello
        )
        do {
            let engineKey = try P256.Signing.PublicKey(
                compressedRepresentation: certificate.machinePublicKey
            )
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: serverHello.engineSignature)
            guard engineKey.isValidSignature(signature, for: t1) else {
                throw OwnerSiteA2PreFinishedHandshakeError.invalidServerSignature
            }
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            throw error
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidServerSignature
        }
        return t1
    }

    private func checkedSignature(
        signer: any OwnerSiteA2TranscriptDigestSigning,
        expectedPublicKey: Data,
        digest: Data
    ) throws -> Data {
        guard digest.count == 32, signer.ownerSiteA2PublicKey == expectedPublicKey else {
            throw OwnerSiteA2PreFinishedHandshakeError.signingFailed
        }
        do {
            let raw = try signer.signOwnerSiteA2TranscriptDigest(digest)
            guard raw.count == 64 else {
                throw OwnerSiteA2PreFinishedHandshakeError.signingFailed
            }
            let publicKey = try P256.Signing.PublicKey(compressedRepresentation: expectedPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
            guard publicKey.isValidSignature(signature, for: digest) else {
                throw OwnerSiteA2PreFinishedHandshakeError.signingFailed
            }
            return raw
        } catch let error as OwnerSiteA2PreFinishedHandshakeError {
            throw error
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.signingFailed
        }
    }
}

/// Fixed canonical M1/M2/M3 frame codec. It remains module-internal so its
/// byte-for-byte corpus witnesses can exercise the production codec directly.
enum OwnerSiteA2PreFinishedCBOR {
    static let maximumFrameBytes = 16 * 1024

    static let noisePrologue = HouseholdCBOR.encode(.array([
        .text(OwnerSiteA2TransportProfile.domain),
        .text("noise-prologue"),
        .unsigned(OwnerSiteA2TransportProfile.version),
        .text(OwnerSiteA2TransportProfile.recordVersion),
        .text(OwnerSiteA2TransportProfile.protocolName),
    ]))

    static func encodeFrame(kind: UInt64, noise: Data) throws -> Data {
        guard (1...3).contains(kind),
              !noise.isEmpty,
              noise.count <= maximumFrameBytes
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return HouseholdCBOR.encode(.map([
            "kind": .unsigned(kind),
            "noise": .bytes(noise),
            "version": .unsigned(OwnerSiteA2TransportProfile.version),
        ]))
    }

    static func decodeFrame(_ bytes: Data, expectedKind: UInt64) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= maximumFrameBytes else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        let map = try decodeCanonicalMap(bytes)
        try requireExactKeys(map, ["kind", "noise", "version"])
        guard try requiredUnsigned(map, "version") == OwnerSiteA2TransportProfile.version,
              try requiredUnsigned(map, "kind") == expectedKind
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        let noise = try requiredBytes(map, "noise")
        guard !noise.isEmpty, noise.count <= maximumFrameBytes else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return noise
    }

    static func decodeCanonicalMap(_ bytes: Data) throws -> [String: HouseholdCBORValue] {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(bytes)
        } catch {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        guard HouseholdCBOR.encode(value) == bytes else {
            throw OwnerSiteA2PreFinishedHandshakeError.nonCanonicalFrame
        }
        guard case let .map(map) = value else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return map
    }

    static func requireExactKeys(_ map: [String: HouseholdCBORValue], _ keys: Set<String>) throws {
        guard Set(map.keys) == keys else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
    }

    static func requiredValue(
        _ map: [String: HouseholdCBORValue],
        _ key: String
    ) throws -> HouseholdCBORValue {
        guard let value = map[key] else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return value
    }

    static func requiredText(_ map: [String: HouseholdCBORValue], _ key: String) throws -> String {
        guard case let .text(value) = try requiredValue(map, key), !value.isEmpty else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return value
    }

    static func requiredBytes(
        _ map: [String: HouseholdCBORValue],
        _ key: String,
        count: Int? = nil
    ) throws -> Data {
        guard case let .bytes(value) = try requiredValue(map, key),
              count.map({ value.count == $0 }) ?? true
        else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return value
    }

    static func requiredUnsigned(
        _ map: [String: HouseholdCBORValue],
        _ key: String,
        nonzero: Bool = false
    ) throws -> UInt64 {
        guard case let .unsigned(value) = try requiredValue(map, key), !nonzero || value > 0 else {
            throw OwnerSiteA2PreFinishedHandshakeError.invalidFrame
        }
        return value
    }
}
