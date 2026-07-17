import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerSiteA2DevicePreFinishedHandshakeTests {
    @Test func a2NoiseProfileReproducesFrozenSyntheticKAT() throws {
        let kat = try OwnerSiteA2TransportKATSupport.load()
        let inputs = kat.synthetic_x25519_private_inputs
        let result = try OwnerSiteA2PreFinishedNoiseKAT.reproduce(
            deviceStatic: try OwnerSiteA2TransportKATSupport.hexData(
                inputs.device_static_hex,
                "device static"
            ),
            deviceEphemeral: try OwnerSiteA2TransportKATSupport.hexData(
                inputs.device_ephemeral_hex,
                "device ephemeral"
            ),
            m1Payload: try OwnerSiteA2TransportKATSupport.hexData(
                kat.m1_payload_canonical_cbor_hex,
                "M1 payload"
            ),
            m2Wire: try OwnerSiteA2TransportKATSupport.hexData(kat.m2_noise_hex, "M2 noise"),
            m3Payload: try OwnerSiteA2TransportKATSupport.hexData(
                kat.m3_payload_canonical_cbor_hex,
                "M3 payload"
            )
        )
        let expectedM1 = try OwnerSiteA2TransportKATSupport.hexData(kat.m1_noise_hex, "M1 noise")
        #expect(result.m1Wire == expectedM1)
        let expectedM2Payload = try OwnerSiteA2TransportKATSupport.hexData(
            kat.m2_payload_canonical_cbor_hex,
            "M2 payload"
        )
        #expect(result.m2Payload == expectedM2Payload)
        let expectedM3 = try OwnerSiteA2TransportKATSupport.hexData(kat.m3_noise_hex, "M3 noise")
        let expectedFinalHash = try OwnerSiteA2TransportKATSupport.hexData(kat.h_final_hex, "H_final")
        #expect(result.m3Wire == expectedM3)
        #expect(result.handshakeHash == expectedFinalHash)
    }

    @Test func frozenSemanticCorpusMatchesProductionCBORTranscriptsAndSignatures() throws {
        let semantic = try semanticCase()
        let ake = try dictionary(semantic, "ake")
        let machineCertificate = try dictionary(semantic, "machine_certificate")
        let membership = try dictionary(semantic, "membership")
        let roster = try dictionary(membership, "roster_harness")
        let request = try dictionary(semantic, "request")

        let c1Bytes = try hex(try string(ake, "client_hello_canonical_cbor_hex"))
        let c1 = try OwnerSiteA2ClientHello.decodeCanonical(c1Bytes)
        let expectedCore = try hex(try string(ake, "client_hello_core_canonical_cbor_hex"))
        #expect(c1.canonicalCBOR() == c1Bytes)
        #expect(c1.core.canonicalCBOR() == expectedCore)

        let m2Bytes = try hex(try string(ake, "server_hello_canonical_cbor_hex"))
        let m2 = try OwnerSiteA2ServerHello.decodeCanonical(m2Bytes)
        #expect(m2.canonicalCBOR() == m2Bytes)

        let m3Bytes = try hex(try string(ake, "client_proof_canonical_cbor_hex"))
        let m3 = try OwnerSiteA2ClientProof.decodeCanonical(m3Bytes)
        #expect(m3.canonicalCBOR() == m3Bytes)

        for (kind, noiseKey, frameKey) in [
            (UInt64(1), "m1_noise_hex", "m1_ws_binary_canonical_cbor_hex"),
            (UInt64(2), "m2_noise_hex", "m2_ws_binary_canonical_cbor_hex"),
            (UInt64(3), "m3_noise_hex", "m3_ws_binary_canonical_cbor_hex"),
        ] {
            let noise = try hex(try string(ake, noiseKey))
            let expectedFrame = try hex(try string(ake, frameKey))
            let frame = try OwnerSiteA2PreFinishedCBOR.encodeFrame(kind: kind, noise: noise)
            #expect(frame == expectedFrame)
            #expect(try OwnerSiteA2PreFinishedCBOR.decodeFrame(frame, expectedKind: kind) == noise)
        }

        let certificateBytes = try hex(try string(machineCertificate, "canonical_cbor_hex"))
        let certificate = try MachineCert(cbor: certificateBytes)
        #expect(certificate.rawCBOR == certificateBytes)
        try MachineCertValidator.validate(
            cert: certificate,
            expectedHouseholdId: try string(request, "household_id"),
            householdPublicKey: try hex(try string(machineCertificate, "household_public_sec1_hex")),
            isRevoked: { _ in false },
            now: Date(timeIntervalSince1970: TimeInterval(try uint(semantic, "now_unix_s")))
        )

        let t1 = try OwnerSiteA2PreFinishedTranscript.serverAuthT1(
            clientHello: c1,
            engineEphemeral: try hex(try string(ake, "engine_ephemeral_x25519_public_hex")),
            engineStatic: try hex(try string(ake, "engine_static_x25519_public_hex")),
            serverHello: m2
        )
        let expectedT1 = try hex(try string(ake, "server_auth_t1_hex"))
        #expect(t1 == expectedT1)
        let engineSignature = try P256.Signing.ECDSASignature(rawRepresentation: m2.engineSignature)
        let enginePublicKey = try P256.Signing.PublicKey(compressedRepresentation: certificate.machinePublicKey)
        #expect(enginePublicKey.isValidSignature(engineSignature, for: t1))

        let authority = try OwnerSiteA2ValidatedAuthority.syntheticTestOnly(
            householdID: try string(request, "household_id"),
            householdPublicKey: try hex(try string(machineCertificate, "household_public_sec1_hex")),
            networkID: try string(request, "network_id"),
            route: try string(request, "route"),
            resource: try string(request, "resource"),
            intentMethod: c1.core.intent.method,
            intentTarget: c1.core.intent.target,
            intentBodyHash: c1.core.intent.bodyHash,
            claimedBindingID: try hex(try string(roster, "binding_id_hex")),
            bindingDigest: try hex(try string(roster, "binding_digest_hex")),
            participantNpub: try string(membership, "participant_npub"),
            channelAuthKeyID: try string(roster, "channel_auth_key_id"),
            channelAuthPublicKey: try hex(try string(roster, "channel_auth_public_sec1_hex")),
            actionPopKeyID: try string(roster, "action_pop_key_id"),
            actionPopPublicKey: try hex(try string(roster, "action_pop_public_sec1_hex")),
            expectedEngineMachineCertificate: certificateBytes,
            expectedEngineMachinePublicKey: try hex(try string(machineCertificate, "machine_public_sec1_hex")),
            expectedEngineKeyID: m2.engineKeyID,
            authzEpoch: m2.authzEpoch,
            rosterDigest: m2.rosterDigest,
            freshUntilUnixSeconds: m2.freshUntilUnixSeconds
        )
        let preBinding = try OwnerSiteA2PreFinishedTranscript.popBindingPre(
            t1: t1,
            deviceStatic: try hex(try string(ake, "device_static_x25519_public_hex"))
        )
        let expectedPreBinding = try hex(try string(ake, "prebinding_hex"))
        #expect(preBinding == expectedPreBinding)
        let deviceAuth = try OwnerSiteA2PreFinishedTranscript.deviceAuth(
            preBinding: preBinding,
            authority: authority
        )
        let expectedDeviceAuth = try hex(try string(ake, "device_auth_hash_hex"))
        #expect(deviceAuth == expectedDeviceAuth)
        let ownerAction = try OwnerSiteA2PreFinishedTranscript.ownerAction(
            preBinding: preBinding,
            authority: authority,
            serverHello: m2,
            clientHelloCore: c1.core
        )
        let expectedOwnerAction = try hex(try string(ake, "owner_action_hash_hex"))
        #expect(ownerAction == expectedOwnerAction)

        let channelKey = try P256.Signing.PublicKey(
            compressedRepresentation: try hex(try string(roster, "channel_auth_public_sec1_hex"))
        )
        let actionKey = try P256.Signing.PublicKey(
            compressedRepresentation: try hex(try string(roster, "action_pop_public_sec1_hex"))
        )
        #expect(
            channelKey.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: m3.deviceSignature),
                for: deviceAuth
            )
        )
        #expect(
            actionKey.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: m3.actionPop),
                for: ownerAction
            )
        )
    }

    @Test func validatedM2ProducesM3ThenMovesExactlyOneFinishedTransport() async throws {
        let fixture = try SyntheticFixture()
        let handshake = try OwnerSiteA2DevicePreFinishedHandshake(
            authority: fixture.authority,
            channelAuthSigner: fixture.channelSigner,
            actionPopSigner: fixture.actionSigner
        )
        let m1Frame = try await handshake.emitM1()
        let m1Noise = try frameNoise(m1Frame, expectedKind: 1)
        let c1 = try OwnerSiteA2ClientHello(
            core: try OwnerSiteA2ClientHelloCore.decodeCanonical(Data(m1Noise.dropFirst(32))),
            deviceEphemeral: Data(m1Noise.prefix(32))
        )

        var responder = try OwnerSiteA2TransportKATSupport.SyntheticResponder(
            m1Noise: m1Noise,
            engineStatic: fixture.engineNoiseStatic,
            engineEphemeral: fixture.engineNoiseEphemeral
        )
        let placeholderM2 = try fixture.serverHello(engineSignature: Data(repeating: 0, count: 64))
        let t1 = try OwnerSiteA2PreFinishedTranscript.serverAuthT1(
            clientHello: c1,
            engineEphemeral: responder.engineEphemeralPublic,
            engineStatic: responder.engineStaticPublic,
            serverHello: placeholderM2
        )
        let m2 = try fixture.serverHello(
            engineSignature: try fixture.engineSigningKey.signature(for: t1).rawRepresentation
        )
        let m2Frame = try makeFrame(kind: 2, noise: try responder.makeM2(payload: m2.canonicalCBOR()))
        let m3Frame = try await handshake.acceptM2AndMakeM3(
            m2Frame,
            trustedNow: .syntheticTestOnly(unixSeconds: fixture.trustedNow)
        )

        let openedM3 = try responder.openM3(try frameNoise(m3Frame, expectedKind: 3))
        let proof = try OwnerSiteA2ClientProof.decodeCanonical(openedM3.payload)
        #expect(proof.bindingID == fixture.bindingID)
        #expect(proof.bindingDigest == fixture.bindingDigest)
        #expect(proof.participantNpub == fixture.participantNpub)
        #expect(proof.channelAuthKeyID == fixture.channelKeyID)
        #expect(proof.actionPopKeyID == fixture.actionKeyID)

        let preBinding = try OwnerSiteA2PreFinishedTranscript.popBindingPre(
            t1: t1,
            deviceStatic: openedM3.deviceStatic
        )
        let deviceAuth = try OwnerSiteA2PreFinishedTranscript.deviceAuth(
            preBinding: preBinding,
            authority: fixture.authority
        )
        let action = try OwnerSiteA2PreFinishedTranscript.ownerAction(
            preBinding: preBinding,
            authority: fixture.authority,
            serverHello: m2,
            clientHelloCore: c1.core
        )
        #expect(
            fixture.channelSigningKey.publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: proof.deviceSignature),
                for: deviceAuth
            )
        )
        #expect(
            fixture.actionSigningKey.publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: proof.actionPop),
                for: action
            )
        )

        let finished = try await handshake.takeFinishedTransport()
        let context = try OwnerSiteA2FinishedContext(
            channelID: fixture.channelID,
            channelEpoch: fixture.channelEpoch,
            bindingID: fixture.bindingID,
            bindingDigest: fixture.bindingDigest,
            authzEpoch: fixture.authzEpoch,
            rosterDigest: fixture.rosterDigest,
            freshUntilUnixSeconds: fixture.freshUntil
        )
        let s2Wire = try OwnerSiteA2TransportKATSupport.makeServerFinishedWire(
            chainingKey: openedM3.chainingKey,
            handshakeHash: openedM3.handshakeHash,
            context: context
        )
        let c3Wire = try await finished.acceptServerFinished(
            s2Wire,
            trustedNow: .syntheticTestOnly(unixSeconds: fixture.trustedNow)
        )
        let c3Plaintext = try OwnerSiteA2TransportKATSupport.decryptClientFinishedAck(
            c3Wire,
            chainingKey: openedM3.chainingKey
        )
        guard case let .array(c3Fields) = try HouseholdCBOR.decode(c3Plaintext) else {
            Issue.record("C3 must be a canonical array")
            return
        }
        #expect(HouseholdCBOR.encode(.array(c3Fields)) == c3Plaintext)
        #expect(c3Fields[2] == .unsigned(OwnerSiteA2RecordKind.clientFinishedAck.rawValue))
        #expect(c3Fields[3] == .unsigned(OwnerSiteA2RecordDirection.deviceToEngine.rawValue))

        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.handoffUnavailable) {
            _ = try await handshake.takeFinishedTransport()
        }
    }

    @Test func malformedM2IsTerminalBeforeEitherSignerRuns() async throws {
        let fixture = try SyntheticFixture()
        let channelSigner = CountingSigner(base: fixture.channelSigner)
        let actionSigner = CountingSigner(base: fixture.actionSigner)
        let handshake = try OwnerSiteA2DevicePreFinishedHandshake(
            authority: fixture.authority,
            channelAuthSigner: channelSigner,
            actionPopSigner: actionSigner
        )
        _ = try await handshake.emitM1()
        let malformedM2 = try makeFrame(kind: 2, noise: Data(repeating: 0, count: 96))

        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.self) {
            _ = try await handshake.acceptM2AndMakeM3(
                malformedM2,
                trustedNow: .syntheticTestOnly(unixSeconds: fixture.trustedNow)
            )
        }
        #expect(channelSigner.calls == 0)
        #expect(actionSigner.calls == 0)
        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.unexpectedState) {
            _ = try await handshake.emitM1()
        }
    }

    @Test func authenticatedButStaleM2IsTerminalBeforeEitherSignerRuns() async throws {
        let fixture = try SyntheticFixture(freshUntil: 1_714_972_800)
        let channelSigner = CountingSigner(base: fixture.channelSigner)
        let actionSigner = CountingSigner(base: fixture.actionSigner)
        let handshake = try OwnerSiteA2DevicePreFinishedHandshake(
            authority: fixture.authority,
            channelAuthSigner: channelSigner,
            actionPopSigner: actionSigner
        )
        let m1Noise = try frameNoise(try await handshake.emitM1(), expectedKind: 1)
        let m2Frame = try signedM2Frame(
            m1Noise: m1Noise,
            fixture: fixture
        )

        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.staleServerHello) {
            _ = try await handshake.acceptM2AndMakeM3(
                m2Frame,
                trustedNow: .syntheticTestOnly(unixSeconds: fixture.trustedNow)
            )
        }
        #expect(channelSigner.calls == 0)
        #expect(actionSigner.calls == 0)
        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.handoffUnavailable) {
            _ = try await handshake.takeFinishedTransport()
        }
    }

    @Test func signedButWrongAuthorityM2IsTerminalBeforeEitherSignerRuns() async throws {
        let fixture = try SyntheticFixture()
        let channelSigner = CountingSigner(base: fixture.channelSigner)
        let actionSigner = CountingSigner(base: fixture.actionSigner)
        let handshake = try OwnerSiteA2DevicePreFinishedHandshake(
            authority: fixture.authority,
            channelAuthSigner: channelSigner,
            actionPopSigner: actionSigner
        )
        let m1Noise = try frameNoise(try await handshake.emitM1(), expectedKind: 1)
        let m2Frame = try signedM2Frame(
            m1Noise: m1Noise,
            fixture: fixture,
            rosterDigest: Data(repeating: 0xA7, count: 32)
        )

        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.serverIdentityMismatch) {
            _ = try await handshake.acceptM2AndMakeM3(
                m2Frame,
                trustedNow: .syntheticTestOnly(unixSeconds: fixture.trustedNow)
            )
        }
        #expect(channelSigner.calls == 0)
        #expect(actionSigner.calls == 0)
        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.handoffUnavailable) {
            _ = try await handshake.takeFinishedTransport()
        }
    }

    @Test func invalidEngineSignatureIsTerminalBeforeEitherSignerRuns() async throws {
        let fixture = try SyntheticFixture()
        let channelSigner = CountingSigner(base: fixture.channelSigner)
        let actionSigner = CountingSigner(base: fixture.actionSigner)
        let handshake = try OwnerSiteA2DevicePreFinishedHandshake(
            authority: fixture.authority,
            channelAuthSigner: channelSigner,
            actionPopSigner: actionSigner
        )
        let m1Noise = try frameNoise(try await handshake.emitM1(), expectedKind: 1)
        let m2Frame = try signedM2Frame(
            m1Noise: m1Noise,
            fixture: fixture,
            engineSignatureOverride: Data(repeating: 0, count: 64)
        )

        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.invalidServerSignature) {
            _ = try await handshake.acceptM2AndMakeM3(
                m2Frame,
                trustedNow: .syntheticTestOnly(unixSeconds: fixture.trustedNow)
            )
        }
        #expect(channelSigner.calls == 0)
        #expect(actionSigner.calls == 0)
        await #expect(throws: OwnerSiteA2PreFinishedHandshakeError.handoffUnavailable) {
            _ = try await handshake.takeFinishedTransport()
        }
    }

    @Test func reusedSignerDoesNotSatisfyBothBoundRoles() throws {
        let fixture = try SyntheticFixture()
        #expect(throws: OwnerSiteA2PreFinishedHandshakeError.invalidSigner) {
            _ = try OwnerSiteA2DevicePreFinishedHandshake(
                authority: fixture.authority,
                channelAuthSigner: fixture.channelSigner,
                actionPopSigner: fixture.channelSigner
            )
        }
    }

    private struct SyntheticFixture {
        let householdSigningKey = P256.Signing.PrivateKey()
        let engineSigningKey = P256.Signing.PrivateKey()
        let channelSigningKey = P256.Signing.PrivateKey()
        let actionSigningKey = P256.Signing.PrivateKey()
        let engineNoiseStatic = Curve25519.KeyAgreement.PrivateKey()
        let engineNoiseEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let channelID = Data(repeating: 0x11, count: 32)
        let challengeID = Data(repeating: 0x22, count: 32)
        let challengeSecret = Data(repeating: 0x33, count: 32)
        let bindingID = Data(repeating: 0x44, count: 32)
        let bindingDigest = Data(repeating: 0x55, count: 32)
        let rosterDigest = Data(repeating: 0x66, count: 32)
        let channelEpoch: UInt64 = 7
        let authzEpoch: UInt64 = 9
        let trustedNow: UInt64 = 1_714_972_800
        let freshUntil: UInt64
        let participantNpub = "npub1syntheticownera2"
        let channelKeyID = "channel-auth-synthetic"
        let actionKeyID = "action-pop-synthetic"
        let engineKeyID = "engine:synthetic.a2"
        let networkID = "owner-site-mesh"
        let route = "/api/v1/household/claws/{name}/owner-site/ake"
        let resource = "picoclaw"
        let householdID: String
        let machineCertificate: Data
        let authority: OwnerSiteA2ValidatedAuthority
        let channelSigner: OwnerSiteA2SoftwareTranscriptSigner
        let actionSigner: OwnerSiteA2SoftwareTranscriptSigner

        init(freshUntil: UInt64 = 1_714_973_400) throws {
            self.freshUntil = freshUntil
            householdID = try HouseholdIdentifiers.householdIdentifier(
                for: householdSigningKey.publicKey.compressedRepresentation
            )
            machineCertificate = try HouseholdTestFixtures.signedMachineCert(
                householdPrivateKey: householdSigningKey,
                machinePublicKey: engineSigningKey.publicKey.compressedRepresentation,
                householdId: householdID,
                hostname: "mac-alpha",
                joinedAt: Date(timeIntervalSince1970: TimeInterval(trustedNow - 60))
            )
            channelSigner = try OwnerSiteA2SoftwareTranscriptSigner(
                keyID: channelKeyID,
                privateKey: channelSigningKey
            )
            actionSigner = try OwnerSiteA2SoftwareTranscriptSigner(
                keyID: actionKeyID,
                privateKey: actionSigningKey
            )
            authority = try OwnerSiteA2ValidatedAuthority.syntheticTestOnly(
                householdID: householdID,
                householdPublicKey: householdSigningKey.publicKey.compressedRepresentation,
                networkID: networkID,
                route: route,
                resource: resource,
                intentMethod: "GET",
                intentTarget: route,
                intentBodyHash: Data(SHA256.hash(data: Data())),
                claimedBindingID: bindingID,
                bindingDigest: bindingDigest,
                participantNpub: participantNpub,
                channelAuthKeyID: channelKeyID,
                channelAuthPublicKey: channelSigningKey.publicKey.compressedRepresentation,
                actionPopKeyID: actionKeyID,
                actionPopPublicKey: actionSigningKey.publicKey.compressedRepresentation,
                expectedEngineMachineCertificate: machineCertificate,
                expectedEngineMachinePublicKey: engineSigningKey.publicKey.compressedRepresentation,
                expectedEngineKeyID: engineKeyID,
                authzEpoch: authzEpoch,
                rosterDigest: rosterDigest,
                freshUntilUnixSeconds: freshUntil
            )
        }

        func serverHello(
            engineSignature: Data,
            rosterDigest overrideRosterDigest: Data? = nil,
            freshUntil overrideFreshUntil: UInt64? = nil
        ) throws -> OwnerSiteA2ServerHello {
            try OwnerSiteA2ServerHello(
                engineMachineCertificate: machineCertificate,
                engineKeyID: engineKeyID,
                channelID: channelID,
                channelEpoch: channelEpoch,
                challengeID: challengeID,
                challengeSecret: challengeSecret,
                authzEpoch: authzEpoch,
                rosterDigest: overrideRosterDigest ?? rosterDigest,
                freshUntilUnixSeconds: overrideFreshUntil ?? freshUntil,
                engineSignature: engineSignature
            )
        }
    }

    private final class CountingSigner: OwnerSiteA2TranscriptDigestSigning, @unchecked Sendable {
        private let base: OwnerSiteA2SoftwareTranscriptSigner
        private(set) var calls = 0

        init(base: OwnerSiteA2SoftwareTranscriptSigner) {
            self.base = base
        }

        var ownerSiteA2KeyID: String { base.ownerSiteA2KeyID }
        var ownerSiteA2PublicKey: Data { base.ownerSiteA2PublicKey }

        func signOwnerSiteA2TranscriptDigest(_ digest: Data) throws -> Data {
            calls += 1
            return try base.signOwnerSiteA2TranscriptDigest(digest)
        }
    }

    private enum FixtureError: Error {
        case malformed
    }

    private func semanticCase() throws -> [String: Any] {
        guard let url = Bundle.module.url(
            forResource: "owner_site_a2_r1_semantic_corpus_v1",
            withExtension: "json",
            subdirectory: "Fixtures/mobile-claw-vpn/v1"
        ),
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            let cases = root["semantic_cases"] as? [[String: Any]],
            let first = cases.first
        else {
            throw FixtureError.malformed
        }
        return first
    }

    private func dictionary(_ map: [String: Any], _ key: String) throws -> [String: Any] {
        guard let result = map[key] as? [String: Any] else { throw FixtureError.malformed }
        return result
    }

    private func string(_ map: [String: Any], _ key: String) throws -> String {
        guard let result = map[key] as? String else { throw FixtureError.malformed }
        return result
    }

    private func uint(_ map: [String: Any], _ key: String) throws -> UInt64 {
        guard let number = map[key] as? NSNumber else { throw FixtureError.malformed }
        return number.uint64Value
    }

    private func hex(_ string: String) throws -> Data {
        try OwnerSiteA2TransportKATSupport.hexData(string, "semantic hex")
    }

    private func makeFrame(kind: UInt64, noise: Data) throws -> Data {
        HouseholdCBOR.encode(.map([
            "kind": .unsigned(kind),
            "noise": .bytes(noise),
            "version": .unsigned(OwnerSiteA2TransportProfile.version),
        ]))
    }

    private func frameNoise(_ frame: Data, expectedKind: UInt64) throws -> Data {
        guard case let .map(map) = try HouseholdCBOR.decode(frame),
              HouseholdCBOR.encode(.map(map)) == frame,
              map["kind"] == .unsigned(expectedKind),
              map["version"] == .unsigned(OwnerSiteA2TransportProfile.version),
              case let .bytes(noise) = map["noise"]
        else {
            throw FixtureError.malformed
        }
        return noise
    }

    private func signedM2Frame(
        m1Noise: Data,
        fixture: SyntheticFixture,
        rosterDigest: Data? = nil,
        freshUntil: UInt64? = nil,
        engineSignatureOverride: Data? = nil
    ) throws -> Data {
        let c1 = try OwnerSiteA2ClientHello(
            core: try OwnerSiteA2ClientHelloCore.decodeCanonical(Data(m1Noise.dropFirst(32))),
            deviceEphemeral: Data(m1Noise.prefix(32))
        )
        var responder = try OwnerSiteA2TransportKATSupport.SyntheticResponder(
            m1Noise: m1Noise,
            engineStatic: fixture.engineNoiseStatic,
            engineEphemeral: fixture.engineNoiseEphemeral
        )
        let unsigned = try fixture.serverHello(
            engineSignature: Data(repeating: 0, count: 64),
            rosterDigest: rosterDigest,
            freshUntil: freshUntil
        )
        let t1 = try OwnerSiteA2PreFinishedTranscript.serverAuthT1(
            clientHello: c1,
            engineEphemeral: responder.engineEphemeralPublic,
            engineStatic: responder.engineStaticPublic,
            serverHello: unsigned
        )
        let signed = try fixture.serverHello(
            engineSignature: engineSignatureOverride
                ?? fixture.engineSigningKey.signature(for: t1).rawRepresentation,
            rosterDigest: rosterDigest,
            freshUntil: freshUntil
        )
        return try makeFrame(kind: 2, noise: try responder.makeM2(payload: signed.canonicalCBOR()))
    }
}
