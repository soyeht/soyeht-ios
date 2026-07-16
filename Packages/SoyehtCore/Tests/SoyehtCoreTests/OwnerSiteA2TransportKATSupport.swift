import CryptoKit
import Foundation

@testable import SoyehtCore

/// Test-only replay of the frozen synthetic Noise XX KAT.
///
/// The corpus intentionally does not serialize `ck_final`; this support derives
/// it from the four synthetic X25519 private inputs so production never needs a
/// fixture-derived key path.
enum OwnerSiteA2TransportKATSupport {
    struct TransportKAT: Decodable {
        struct ChannelContext: Decodable {
            let authz_epoch: UInt64
            let binding_digest_hex: String
            let binding_id_hex: String
            let channel_epoch: UInt64
            let channel_id_hex: String
            let fresh_until_unix_s: UInt64
            let kat_now_unix_s: UInt64
            let roster_digest_hex: String
        }

        struct SyntheticPrivateInputs: Decodable {
            let device_ephemeral_hex: String
            let device_static_hex: String
            let engine_ephemeral_hex: String
            let engine_static_hex: String
        }

        let c3_wire_hex: String
        let channel_binding_hex: String
        let channel_context: ChannelContext
        let h_final_hex: String
        let hs2_hex: String
        let m1_noise_hex: String
        let m1_payload_canonical_cbor_hex: String
        let m2_noise_hex: String
        let m2_payload_canonical_cbor_hex: String
        let m3_noise_hex: String
        let m3_payload_canonical_cbor_hex: String
        let p_a2_canonical_cbor_hex: String
        let protocol_name: String
        let protocol_name_ascii_hex: String
        let s2_wire_hex: String
        let synthetic_x25519_private_inputs: SyntheticPrivateInputs
    }

    private struct Corpus: Decodable {
        let transport_kat_a2_r1: TransportKAT
    }

    enum Failure: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case let .message(value): value
            }
        }
    }

    static func load() throws -> TransportKAT {
        guard let url = Bundle.module.url(
            forResource: "owner_site_a2_r1_semantic_corpus_v1",
            withExtension: "json",
            subdirectory: "Fixtures/mobile-claw-vpn/v1"
        ) else {
            throw Failure.message("missing frozen A2-R1 corpus")
        }
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url)).transport_kat_a2_r1
    }

    static func completedPreFinished(
        _ kat: TransportKAT
    ) throws -> OwnerSiteA2ValidatedPreFinished {
        let replay = try replayNoiseXX(kat)
        let context = kat.channel_context
        return try OwnerSiteA2ValidatedPreFinished.syntheticTestOnly(
            chainingKey: replay.chainingKey,
            handshakeHash: replay.handshakeHash,
            context: try OwnerSiteA2FinishedContext(
                channelID: try hexData(context.channel_id_hex, "channel_id"),
                channelEpoch: context.channel_epoch,
                bindingID: try hexData(context.binding_id_hex, "binding_id"),
                bindingDigest: try hexData(context.binding_digest_hex, "binding_digest"),
                authzEpoch: context.authz_epoch,
                rosterDigest: try hexData(context.roster_digest_hex, "roster_digest"),
                freshUntilUnixSeconds: context.fresh_until_unix_s
            )
        )
    }

    static func replayNoiseXX(_ kat: TransportKAT) throws -> (chainingKey: Data, handshakeHash: Data) {
        try require(
            kat.protocol_name == OwnerSiteA2TransportProfile.protocolName,
            "protocol name drift"
        )
        try require(
            Data(kat.protocol_name.utf8) == hexData(kat.protocol_name_ascii_hex, "protocol_name_ascii_hex"),
            "protocol name bytes drift"
        )

        let prologue = canonicalArray([
            .text(OwnerSiteA2TransportProfile.domain),
            .text("noise-prologue"),
            .unsigned(OwnerSiteA2TransportProfile.version),
            .text(OwnerSiteA2TransportProfile.recordVersion),
            .text(OwnerSiteA2TransportProfile.protocolName),
        ])
        try require(prologue == hexData(kat.p_a2_canonical_cbor_hex, "P_A2"), "prologue drift")

        let m1Payload = canonicalArray([
            .text(OwnerSiteA2TransportProfile.domain), .unsigned(1), .text("fixture-m1"),
        ])
        let m2Payload = canonicalArray([
            .text(OwnerSiteA2TransportProfile.domain), .unsigned(1), .text("fixture-m2"),
        ])
        let m3Payload = canonicalArray([
            .text(OwnerSiteA2TransportProfile.domain), .unsigned(1), .text("fixture-m3"),
        ])
        try require(m1Payload == hexData(kat.m1_payload_canonical_cbor_hex, "M1 payload"), "M1 payload drift")
        try require(m2Payload == hexData(kat.m2_payload_canonical_cbor_hex, "M2 payload"), "M2 payload drift")
        try require(m3Payload == hexData(kat.m3_payload_canonical_cbor_hex, "M3 payload"), "M3 payload drift")

        let inputs = kat.synthetic_x25519_private_inputs
        let deviceStatic = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hexData(inputs.device_static_hex, "device static")
        )
        let deviceEphemeral = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hexData(inputs.device_ephemeral_hex, "device ephemeral")
        )
        let engineStatic = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hexData(inputs.engine_static_hex, "engine static")
        )
        let engineEphemeral = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hexData(inputs.engine_ephemeral_hex, "engine ephemeral")
        )

        var device = NoiseSymmetricState(protocolName: Data(kat.protocol_name.utf8), prologue: prologue)
        var engine = NoiseSymmetricState(protocolName: Data(kat.protocol_name.utf8), prologue: prologue)

        let deviceEphemeralPublic = deviceEphemeral.publicKey.rawRepresentation
        var m1 = deviceEphemeralPublic
        device.mixHash(deviceEphemeralPublic)
        m1.append(try device.encryptAndHash(m1Payload))
        try require(m1 == hexData(kat.m1_noise_hex, "M1_noise"), "M1 wire drift")

        let receivedDeviceEphemeral = Data(m1.prefix(32))
        engine.mixHash(receivedDeviceEphemeral)
        try require(
            try engine.decryptAndHash(Data(m1.dropFirst(32))) == m1Payload,
            "M1 inverse mismatch"
        )

        let engineEphemeralPublic = engineEphemeral.publicKey.rawRepresentation
        var m2 = engineEphemeralPublic
        engine.mixHash(engineEphemeralPublic)
        engine.mixKey(try sharedSecret(engineEphemeral, receivedDeviceEphemeral))
        m2.append(try engine.encryptAndHash(engineStatic.publicKey.rawRepresentation))
        engine.mixKey(try sharedSecret(engineStatic, receivedDeviceEphemeral))
        m2.append(try engine.encryptAndHash(m2Payload))
        try require(m2 == hexData(kat.m2_noise_hex, "M2_noise"), "M2 wire drift")

        let receivedEngineEphemeral = Data(m2.prefix(32))
        device.mixHash(receivedEngineEphemeral)
        device.mixKey(try sharedSecret(deviceEphemeral, receivedEngineEphemeral))
        let receivedEngineStatic = try device.decryptAndHash(Data(m2[32..<80]))
        try require(receivedEngineStatic == engineStatic.publicKey.rawRepresentation, "M2 static mismatch")
        device.mixKey(try sharedSecret(deviceEphemeral, receivedEngineStatic))
        try require(
            try device.decryptAndHash(Data(m2.dropFirst(80))) == m2Payload,
            "M2 inverse mismatch"
        )

        var m3 = try device.encryptAndHash(deviceStatic.publicKey.rawRepresentation)
        device.mixKey(try sharedSecret(deviceStatic, receivedEngineEphemeral))
        m3.append(try device.encryptAndHash(m3Payload))
        try require(m3 == hexData(kat.m3_noise_hex, "M3_noise"), "M3 wire drift")

        let receivedDeviceStatic = try engine.decryptAndHash(Data(m3.prefix(48)))
        try require(receivedDeviceStatic == deviceStatic.publicKey.rawRepresentation, "M3 static mismatch")
        engine.mixKey(try sharedSecret(engineEphemeral, receivedDeviceStatic))
        try require(
            try engine.decryptAndHash(Data(m3.dropFirst(48))) == m3Payload,
            "M3 inverse mismatch"
        )

        try require(device.handshakeHash == engine.handshakeHash, "handshake hash direction mismatch")
        try require(device.handshakeHash == hexData(kat.h_final_hex, "H_final"), "H_final drift")
        return (device.chainingKey, device.handshakeHash)
    }

    static func split(chainingKey: Data) -> (deviceToEngine: Data, engineToDevice: Data) {
        let temporaryKey = hmacSHA256(key: chainingKey, message: Data())
        let deviceToEngine = hmacSHA256(key: temporaryKey, message: Data([1]))
        let engineToDevice = hmacSHA256(key: temporaryKey, message: deviceToEngine + Data([2]))
        return (deviceToEngine, engineToDevice)
    }

    static func makeServerFinishedWire(
        kat: TransportKAT,
        chainingKey: Data,
        mutate: (inout [HouseholdCBORValue]) -> Void = { _ in }
    ) throws -> Data {
        let plaintext = try makeServerFinishedPlaintext(kat: kat, mutate: mutate)
        return try sealServerFinishedPlaintext(plaintext, chainingKey: chainingKey)
    }

    static func makeServerFinishedPlaintext(
        kat: TransportKAT,
        mutate: (inout [HouseholdCBORValue]) -> Void = { _ in }
    ) throws -> Data {
        let context = kat.channel_context
        let hFinal = try hexData(kat.h_final_hex, "H_final")
        let channelBinding = try hexData(kat.channel_binding_hex, "CB")
        var fields: [HouseholdCBORValue] = [
            .text(OwnerSiteA2TransportProfile.domain),
            .unsigned(1),
            .unsigned(OwnerSiteA2RecordKind.serverFinished.rawValue),
            .unsigned(OwnerSiteA2RecordDirection.engineToDevice.rawValue),
            .unsigned(0),
            .bytes(try hexData(context.channel_id_hex, "channel_id")),
            .unsigned(context.channel_epoch),
            .bytes(hFinal),
            .bytes(channelBinding),
            .bytes(try hexData(context.binding_id_hex, "binding_id")),
            .bytes(try hexData(context.binding_digest_hex, "binding_digest")),
            .unsigned(context.authz_epoch),
            .bytes(try hexData(context.roster_digest_hex, "roster_digest")),
            .unsigned(context.fresh_until_unix_s),
        ]
        mutate(&fields)
        return canonicalArray(fields)
    }

    static func sealServerFinishedPlaintext(
        _ plaintext: Data,
        chainingKey: Data
    ) throws -> Data {
        var cipher = RecordCipher(key: split(chainingKey: chainingKey).engineToDevice)
        let ciphertext = try cipher.seal(plaintext)
        return canonicalArray([.unsigned(1), .bytes(ciphertext)])
    }

    static func decryptClientFinishedAck(
        _ c3Wire: Data,
        chainingKey: Data
    ) throws -> Data {
        let ciphertext = try envelopeCiphertext(c3Wire)
        var cipher = RecordCipher(key: split(chainingKey: chainingKey).deviceToEngine)
        return try cipher.open(ciphertext)
    }

    static func envelopeCiphertext(_ wire: Data) throws -> Data {
        let value = try HouseholdCBOR.decode(wire)
        try require(HouseholdCBOR.encode(value) == wire, "noncanonical test envelope")
        guard case let .array(fields) = value,
              fields.count == 2,
              case .unsigned(1) = fields[0],
              case let .bytes(ciphertext) = fields[1]
        else {
            throw Failure.message("invalid test envelope")
        }
        return ciphertext
    }

    static func hexData(_ value: String, _ label: String) throws -> Data {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else {
            throw Failure.message("\(label): invalid hex length")
        }
        var result = Data()
        result.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw Failure.message("\(label): invalid hex")
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func canonicalArray(_ values: [HouseholdCBORValue]) -> Data {
        HouseholdCBOR.encode(.array(values))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.message(message) }
    }

    private static func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func sharedSecret(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        _ remotePublic: Data
    ) throws -> Data {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublic)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
        return secret.withUnsafeBytes { Data($0) }
    }

    private struct NoiseCipherState {
        private var key: Data?
        private var nonce: UInt64 = 0

        mutating func setKey(_ key: Data) {
            self.key = key
            nonce = 0
        }

        mutating func encryptAndIncrement(_ plaintext: Data, ad: Data) throws -> Data {
            guard let key else { return plaintext }
            let nonce = try Self.nonce(nonce)
            let sealed = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: nonce,
                authenticating: ad
            )
            self.nonce += 1
            return sealed.ciphertext + sealed.tag
        }

        mutating func decryptAndIncrement(_ ciphertextAndTag: Data, ad: Data) throws -> Data {
            guard let key else { return ciphertextAndTag }
            guard ciphertextAndTag.count >= OwnerSiteA2TransportProfile.authenticationTagBytes else {
                throw Failure.message("short test Noise ciphertext")
            }
            let nonce = try Self.nonce(nonce)
            let sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ciphertextAndTag.dropLast(OwnerSiteA2TransportProfile.authenticationTagBytes),
                tag: ciphertextAndTag.suffix(OwnerSiteA2TransportProfile.authenticationTagBytes)
            )
            let plaintext = try ChaChaPoly.open(sealed, using: SymmetricKey(data: key), authenticating: ad)
            self.nonce += 1
            return plaintext
        }

        private static func nonce(_ sequence: UInt64) throws -> ChaChaPoly.Nonce {
            var bytes = Data(repeating: 0, count: 4)
            var littleEndian = sequence.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            return try ChaChaPoly.Nonce(data: bytes)
        }
    }

    private struct NoiseSymmetricState {
        private(set) var chainingKey: Data
        private(set) var handshakeHash: Data
        private var cipher = NoiseCipherState()

        init(protocolName: Data, prologue: Data) {
            handshakeHash = protocolName.count <= 32
                ? protocolName + Data(repeating: 0, count: 32 - protocolName.count)
                : Data(SHA256.hash(data: protocolName))
            chainingKey = handshakeHash
            mixHash(prologue)
        }

        mutating func mixHash(_ bytes: Data) {
            handshakeHash = Data(SHA256.hash(data: handshakeHash + bytes))
        }

        mutating func mixKey(_ inputKeyMaterial: Data) {
            let temporaryKey = hmacSHA256(key: chainingKey, message: inputKeyMaterial)
            let nextChainingKey = hmacSHA256(key: temporaryKey, message: Data([1]))
            let cipherKey = hmacSHA256(key: temporaryKey, message: nextChainingKey + Data([2]))
            chainingKey = nextChainingKey
            cipher.setKey(cipherKey)
        }

        mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
            let ciphertext = try cipher.encryptAndIncrement(plaintext, ad: handshakeHash)
            mixHash(ciphertext)
            return ciphertext
        }

        mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
            let plaintext = try cipher.decryptAndIncrement(ciphertext, ad: handshakeHash)
            mixHash(ciphertext)
            return plaintext
        }
    }

    private struct RecordCipher {
        private let key: Data
        private var nonce: UInt64 = 0

        init(key: Data) {
            self.key = key
        }

        mutating func seal(_ plaintext: Data) throws -> Data {
            let nonce = try Self.nonce(nonce)
            let sealed = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: nonce,
                authenticating: Data()
            )
            self.nonce += 1
            return sealed.ciphertext + sealed.tag
        }

        mutating func open(_ ciphertextAndTag: Data) throws -> Data {
            guard ciphertextAndTag.count >= OwnerSiteA2TransportProfile.authenticationTagBytes else {
                throw Failure.message("short test record ciphertext")
            }
            let nonce = try Self.nonce(nonce)
            let sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ciphertextAndTag.dropLast(OwnerSiteA2TransportProfile.authenticationTagBytes),
                tag: ciphertextAndTag.suffix(OwnerSiteA2TransportProfile.authenticationTagBytes)
            )
            let plaintext = try ChaChaPoly.open(sealed, using: SymmetricKey(data: key), authenticating: Data())
            self.nonce += 1
            return plaintext
        }

        private static func nonce(_ sequence: UInt64) throws -> ChaChaPoly.Nonce {
            var bytes = Data(repeating: 0, count: 4)
            var littleEndian = sequence.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            return try ChaChaPoly.Nonce(data: bytes)
        }
    }
}
