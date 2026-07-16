import CryptoKit
import Foundation

/// Fail-closed errors for the internal, device-role A2 Finished record state.
///
/// These errors intentionally carry no key, ciphertext, or channel material.
enum OwnerSiteA2TransportError: Error, Equatable, Sendable {
    case invalidPreFinishedMaterial
    case invalidFinishedContext
    case invalidEnvelope
    case nonCanonicalEnvelope
    case invalidCiphertextLength
    case authenticationFailed
    case invalidRecord
    case nonCanonicalRecord
    case serverFinishedMismatch
    case staleServerFinished
    case unexpectedRecordState
    case nonceExhausted
}

/// The exact, already-validated context that S2 must repeat after M3.
///
/// This is package-internal: a future A2 handshake implementation constructs it
/// only after validated M1/M2/M3. It is not an authority, peer, or dial permit.
struct OwnerSiteA2FinishedContext: Equatable, Sendable {
    let channelID: Data
    let channelEpoch: UInt64
    let bindingID: Data
    let bindingDigest: Data
    let authzEpoch: UInt64
    let rosterDigest: Data
    let freshUntilUnixSeconds: UInt64

    init(
        channelID: Data,
        channelEpoch: UInt64,
        bindingID: Data,
        bindingDigest: Data,
        authzEpoch: UInt64,
        rosterDigest: Data,
        freshUntilUnixSeconds: UInt64
    ) throws {
        guard channelID.count == 32,
              bindingID.count == 32,
              bindingDigest.count == 32,
              rosterDigest.count == 32,
              channelEpoch > 0,
              authzEpoch > 0
        else {
            throw OwnerSiteA2TransportError.invalidFinishedContext
        }

        self.channelID = channelID
        self.channelEpoch = channelEpoch
        self.bindingID = bindingID
        self.bindingDigest = bindingDigest
        self.authzEpoch = authzEpoch
        self.rosterDigest = rosterDigest
        self.freshUntilUnixSeconds = freshUntilUnixSeconds
    }
}

/// Opaque internal handoff reserved for the future validated M1/M2/M3 slice.
///
/// The chaining key never leaves this value or the private state machine below;
/// no raw Split key or application exporter is exposed.
struct OwnerSiteA2ValidatedPreFinished {
    private let chainingKey: SymmetricKey
    let handshakeHash: Data
    let context: OwnerSiteA2FinishedContext

    private init(
        chainingKey: Data,
        handshakeHash: Data,
        context: OwnerSiteA2FinishedContext
    ) throws {
        guard chainingKey.count == 32, handshakeHash.count == 32 else {
            throw OwnerSiteA2TransportError.invalidPreFinishedMaterial
        }
        self.chainingKey = SymmetricKey(data: chainingKey)
        self.handshakeHash = handshakeHash
        self.context = context
    }

#if DEBUG
    /// Synthetic KAT-only construction. Release code gains a producer only in
    /// the future verified M1/M2/M3 handoff slice.
    static func syntheticTestOnly(
        chainingKey: Data,
        handshakeHash: Data,
        context: OwnerSiteA2FinishedContext
    ) throws -> OwnerSiteA2ValidatedPreFinished {
        try OwnerSiteA2ValidatedPreFinished(
            chainingKey: chainingKey,
            handshakeHash: handshakeHash,
            context: context
        )
    }
#endif

    fileprivate func makeDirectionalCipherStates() -> (
        deviceToEngine: OwnerSiteA2DirectionalCipherState,
        engineToDevice: OwnerSiteA2DirectionalCipherState
    ) {
        // Noise Split(): HKDF-Extract(salt = ck_final, IKM = epsilon), then
        // expand two 32-byte CipherState keys. No application KDF/exporter.
        let prk = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: Data()),
            salt: chainingKey.withUnsafeBytes { Data($0) }
        )
        let split = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data(),
            outputByteCount: 64
        )
        let bytes = split.withUnsafeBytes { Data($0) }
        return (
            OwnerSiteA2DirectionalCipherState(key: SymmetricKey(data: bytes.prefix(32))),
            OwnerSiteA2DirectionalCipherState(key: SymmetricKey(data: bytes.suffix(32)))
        )
    }
}

/// A trusted UTC reading supplied by a future authority-bound clock source.
/// No arbitrary Unix timestamp is accepted by the Finished transport.
struct OwnerSiteA2TrustedUTC: Sendable {
    fileprivate let unixSeconds: UInt64

    private init(unixSeconds: UInt64) {
        self.unixSeconds = unixSeconds
    }

#if DEBUG
    /// Synthetic KAT-only clock capability.
    static func syntheticTestOnly(unixSeconds: UInt64) -> OwnerSiteA2TrustedUTC {
        OwnerSiteA2TrustedUTC(unixSeconds: unixSeconds)
    }
#endif
}

/// Device-role, post-M3 Finished state. Actor isolation prevents concurrent
/// writers/readers from sharing a directional nonce sequence.
///
/// This type has no network, peer, proxy, persistence, or site-payload API.
/// It accepts one E→D S2 and returns the corresponding D→E C3 bytes.
actor OwnerSiteA2DeviceFinishedTransport {
    private enum Phase {
        case awaitingServerFinished
        case closed
    }

    private let handshakeHash: Data
    private let channelBinding: Data
    private let context: OwnerSiteA2FinishedContext
    private var deviceToEngine: OwnerSiteA2DirectionalCipherState?
    private var engineToDevice: OwnerSiteA2DirectionalCipherState?
    private var phase: Phase = .awaitingServerFinished

    init(validatedPreFinished: OwnerSiteA2ValidatedPreFinished) {
        handshakeHash = validatedPreFinished.handshakeHash
        context = validatedPreFinished.context
        channelBinding = Self.makeChannelBinding(
            handshakeHash: validatedPreFinished.handshakeHash,
            channelID: validatedPreFinished.context.channelID,
            channelEpoch: validatedPreFinished.context.channelEpoch
        )
        let states = validatedPreFinished.makeDirectionalCipherStates()
        deviceToEngine = states.deviceToEngine
        engineToDevice = states.engineToDevice
    }

    /// Authenticates and validates exactly one S2, then returns canonical C3.
    /// Every malformed, stale, out-of-order, or unauthenticated input terminally
    /// closes this local state; callers cannot reset or reuse it.
    func acceptServerFinished(
        _ s2Wire: Data,
        trustedNow: OwnerSiteA2TrustedUTC
    ) throws -> Data {
        guard phase == .awaitingServerFinished else {
            close()
            throw OwnerSiteA2TransportError.unexpectedRecordState
        }

        do {
            let ciphertext = try OwnerSiteA2RecordEnvelope.decode(s2Wire)
            guard var receivingState = engineToDevice else {
                throw OwnerSiteA2TransportError.unexpectedRecordState
            }
            let opened = try receivingState.open(ciphertext)
            engineToDevice = receivingState
            try validateServerFinished(
                plaintext: opened.plaintext,
                expectedSequence: opened.sequence,
                trustedNow: trustedNow
            )

            let hs2 = Self.sha256(OwnerSiteA2RecordCodec.canonicalArray([
                .text(OwnerSiteA2TransportProfile.domain),
                .text("s2-wire"),
                .unsigned(OwnerSiteA2TransportProfile.version),
                .bytes(s2Wire),
            ]))
            guard var sendingState = deviceToEngine else {
                throw OwnerSiteA2TransportError.unexpectedRecordState
            }
            let c3Sequence = try sendingState.expectedSequence()
            let c3Plaintext = OwnerSiteA2RecordCodec.canonicalArray([
                .text(OwnerSiteA2TransportProfile.domain),
                .unsigned(OwnerSiteA2TransportProfile.version),
                .unsigned(OwnerSiteA2RecordKind.clientFinishedAck.rawValue),
                .unsigned(OwnerSiteA2RecordDirection.deviceToEngine.rawValue),
                .unsigned(c3Sequence),
                .bytes(context.channelID),
                .unsigned(context.channelEpoch),
                .bytes(handshakeHash),
                .bytes(channelBinding),
                .bytes(context.bindingID),
                .bytes(context.bindingDigest),
                .unsigned(context.authzEpoch),
                .bytes(context.rosterDigest),
                .unsigned(context.freshUntilUnixSeconds),
                .bytes(hs2),
            ])
            let c3Ciphertext = try sendingState.seal(c3Plaintext)
            deviceToEngine = sendingState
            let c3Wire = try OwnerSiteA2RecordEnvelope.encode(c3Ciphertext)
            close()
            return c3Wire
        } catch let error as OwnerSiteA2TransportError {
            close()
            throw error
        } catch {
            close()
            throw OwnerSiteA2TransportError.authenticationFailed
        }
    }

    private func validateServerFinished(
        plaintext: Data,
        expectedSequence: UInt64,
        trustedNow: OwnerSiteA2TrustedUTC
    ) throws {
        let fields = try OwnerSiteA2RecordCodec.decodeCanonicalArray(plaintext)
        guard fields.count == 14,
              OwnerSiteA2RecordCodec.text(fields[0]) == OwnerSiteA2TransportProfile.domain,
              OwnerSiteA2RecordCodec.unsigned(fields[1]) == OwnerSiteA2TransportProfile.version,
              OwnerSiteA2RecordCodec.unsigned(fields[2]) == OwnerSiteA2RecordKind.serverFinished.rawValue,
              OwnerSiteA2RecordCodec.unsigned(fields[3]) == OwnerSiteA2RecordDirection.engineToDevice.rawValue,
              OwnerSiteA2RecordCodec.unsigned(fields[4]) == expectedSequence,
              OwnerSiteA2RecordCodec.bytes(fields[5]) == context.channelID,
              OwnerSiteA2RecordCodec.unsigned(fields[6]) == context.channelEpoch,
              OwnerSiteA2RecordCodec.bytes(fields[7]) == handshakeHash,
              OwnerSiteA2RecordCodec.bytes(fields[8]) == channelBinding,
              OwnerSiteA2RecordCodec.bytes(fields[9]) == context.bindingID,
              OwnerSiteA2RecordCodec.bytes(fields[10]) == context.bindingDigest,
              OwnerSiteA2RecordCodec.unsigned(fields[11]) == context.authzEpoch,
              OwnerSiteA2RecordCodec.bytes(fields[12]) == context.rosterDigest,
              OwnerSiteA2RecordCodec.unsigned(fields[13]) == context.freshUntilUnixSeconds
        else {
            throw OwnerSiteA2TransportError.serverFinishedMismatch
        }

        guard context.freshUntilUnixSeconds > trustedNow.unixSeconds else {
            throw OwnerSiteA2TransportError.staleServerFinished
        }
    }

    private func close() {
        deviceToEngine = nil
        engineToDevice = nil
        phase = .closed
    }

    private static func makeChannelBinding(
        handshakeHash: Data,
        channelID: Data,
        channelEpoch: UInt64
    ) -> Data {
        sha256(OwnerSiteA2RecordCodec.canonicalArray([
            .text(OwnerSiteA2TransportProfile.domain),
            .text("channel-binding"),
            .unsigned(OwnerSiteA2TransportProfile.version),
            .text(OwnerSiteA2TransportProfile.recordVersion),
            .text(OwnerSiteA2TransportProfile.protocolName),
            .bytes(handshakeHash),
            .bytes(channelID),
            .unsigned(channelEpoch),
        ]))
    }

    private static func sha256(_ bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }
}

/// One private directional CipherState backed by the platform ChaChaPoly
/// primitive. Its counter begins at zero and never supports reset or key rotation.
private struct OwnerSiteA2DirectionalCipherState {
    private let key: SymmetricKey
    private var nextNonce: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= OwnerSiteA2TransportProfile.maximumPlaintextBytes else {
            throw OwnerSiteA2TransportError.invalidCiphertextLength
        }
        let sequence = try reserveNonce()
        do {
            let sealed = try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: try Self.nonce(for: sequence),
                authenticating: Data()
            )
            return sealed.ciphertext + sealed.tag
        } catch let error as OwnerSiteA2TransportError {
            throw error
        } catch {
            throw OwnerSiteA2TransportError.authenticationFailed
        }
    }

    func expectedSequence() throws -> UInt64 {
        guard nextNonce < UInt64.max else {
            throw OwnerSiteA2TransportError.nonceExhausted
        }
        return nextNonce
    }

    mutating func open(_ ciphertext: Data) throws -> (plaintext: Data, sequence: UInt64) {
        guard ciphertext.count >= OwnerSiteA2TransportProfile.authenticationTagBytes,
              ciphertext.count <= OwnerSiteA2TransportProfile.maximumCiphertextBytes
        else {
            throw OwnerSiteA2TransportError.invalidCiphertextLength
        }

        let sequence = try reserveNonce()
        do {
            let sealed = try ChaChaPoly.SealedBox(
                nonce: try Self.nonce(for: sequence),
                ciphertext: ciphertext.dropLast(OwnerSiteA2TransportProfile.authenticationTagBytes),
                tag: ciphertext.suffix(OwnerSiteA2TransportProfile.authenticationTagBytes)
            )
            let plaintext = try ChaChaPoly.open(sealed, using: key, authenticating: Data())
            guard plaintext.count <= OwnerSiteA2TransportProfile.maximumPlaintextBytes else {
                throw OwnerSiteA2TransportError.invalidCiphertextLength
            }
            return (plaintext, sequence)
        } catch let error as OwnerSiteA2TransportError {
            throw error
        } catch {
            throw OwnerSiteA2TransportError.authenticationFailed
        }
    }

    private mutating func reserveNonce() throws -> UInt64 {
        guard nextNonce < UInt64.max else {
            throw OwnerSiteA2TransportError.nonceExhausted
        }
        defer { nextNonce += 1 }
        return nextNonce
    }

    private static func nonce(for sequence: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        var littleEndian = sequence.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

private enum OwnerSiteA2RecordEnvelope {
    static func decode(_ wire: Data) throws -> Data {
        guard !wire.isEmpty, wire.count <= OwnerSiteA2TransportProfile.maximumEnvelopeBytes else {
            throw OwnerSiteA2TransportError.invalidEnvelope
        }
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(wire)
        } catch {
            throw OwnerSiteA2TransportError.invalidEnvelope
        }
        guard HouseholdCBOR.encode(value) == wire else {
            throw OwnerSiteA2TransportError.nonCanonicalEnvelope
        }
        guard case let .array(fields) = value,
              fields.count == 2,
              OwnerSiteA2RecordCodec.unsigned(fields[0]) == OwnerSiteA2TransportProfile.version,
              let ciphertext = OwnerSiteA2RecordCodec.bytes(fields[1]),
              ciphertext.count >= OwnerSiteA2TransportProfile.authenticationTagBytes,
              ciphertext.count <= OwnerSiteA2TransportProfile.maximumCiphertextBytes
        else {
            throw OwnerSiteA2TransportError.invalidEnvelope
        }
        return ciphertext
    }

    static func encode(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count >= OwnerSiteA2TransportProfile.authenticationTagBytes,
              ciphertext.count <= OwnerSiteA2TransportProfile.maximumCiphertextBytes
        else {
            throw OwnerSiteA2TransportError.invalidCiphertextLength
        }
        let wire = OwnerSiteA2RecordCodec.canonicalArray([
            .unsigned(OwnerSiteA2TransportProfile.version),
            .bytes(ciphertext),
        ])
        guard wire.count <= OwnerSiteA2TransportProfile.maximumEnvelopeBytes else {
            throw OwnerSiteA2TransportError.invalidEnvelope
        }
        return wire
    }
}

private enum OwnerSiteA2RecordCodec {
    static func canonicalArray(_ fields: [HouseholdCBORValue]) -> Data {
        HouseholdCBOR.encode(.array(fields))
    }

    static func decodeCanonicalArray(_ bytes: Data) throws -> [HouseholdCBORValue] {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(bytes)
        } catch {
            throw OwnerSiteA2TransportError.invalidRecord
        }
        guard HouseholdCBOR.encode(value) == bytes else {
            throw OwnerSiteA2TransportError.nonCanonicalRecord
        }
        guard case let .array(fields) = value else {
            throw OwnerSiteA2TransportError.invalidRecord
        }
        return fields
    }

    static func unsigned(_ value: HouseholdCBORValue) -> UInt64? {
        guard case let .unsigned(result) = value else { return nil }
        return result
    }

    static func bytes(_ value: HouseholdCBORValue) -> Data? {
        guard case let .bytes(result) = value else { return nil }
        return result
    }

    static func text(_ value: HouseholdCBORValue) -> String? {
        guard case let .text(result) = value else { return nil }
        return result
    }
}
