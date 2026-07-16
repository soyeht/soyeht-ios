import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerSiteA2DeviceFinishedTransportTests {
    @Test func acceptsFrozenS2AndEmitsFrozenC3ByteForByte() async throws {
        let kat = try OwnerSiteA2TransportKATSupport.load()
        let replay = try OwnerSiteA2TransportKATSupport.replayNoiseXX(kat)
        let transport = OwnerSiteA2DeviceFinishedTransport(
            validatedPreFinished: try OwnerSiteA2TransportKATSupport.completedPreFinished(kat)
        )
        let s2Wire = try OwnerSiteA2TransportKATSupport.hexData(kat.s2_wire_hex, "S2_wire")

        let c3Wire = try await transport.acceptServerFinished(
            s2Wire,
            trustedNow: .syntheticTestOnly(unixSeconds: kat.channel_context.kat_now_unix_s)
        )

        let expectedC3Wire = try OwnerSiteA2TransportKATSupport.hexData(kat.c3_wire_hex, "C3_wire")
        #expect(c3Wire == expectedC3Wire)

        let c3Plaintext = try OwnerSiteA2TransportKATSupport.decryptClientFinishedAck(
            c3Wire,
            chainingKey: replay.chainingKey
        )
        let c3Value = try HouseholdCBOR.decode(c3Plaintext)
        guard case let .array(c3Fields) = c3Value else {
            Issue.record("C3 plaintext must be an array")
            return
        }
        #expect(HouseholdCBOR.encode(c3Value) == c3Plaintext)
        #expect(c3Fields.count == 15)
        #expect(c3Fields[2] == .unsigned(OwnerSiteA2RecordKind.clientFinishedAck.rawValue))
        #expect(c3Fields[3] == .unsigned(OwnerSiteA2RecordDirection.deviceToEngine.rawValue))
        #expect(c3Fields[4] == .unsigned(0))
        #expect(c3Fields[14] == .bytes(try OwnerSiteA2TransportKATSupport.hexData(kat.hs2_hex, "HS2")))
    }

    @Test func everyFrozenS2WireByteTamperAndWrongDirectionFailClosed() async throws {
        let kat = try OwnerSiteA2TransportKATSupport.load()
        let preFinished = try OwnerSiteA2TransportKATSupport.completedPreFinished(kat)
        let s2Wire = try OwnerSiteA2TransportKATSupport.hexData(kat.s2_wire_hex, "S2_wire")
        let trustedNow = OwnerSiteA2TrustedUTC.syntheticTestOnly(
            unixSeconds: kat.channel_context.kat_now_unix_s
        )

        for index in s2Wire.indices {
            var tampered = s2Wire
            tampered[index] ^= 0x01
            let transport = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
            await #expect(throws: OwnerSiteA2TransportError.self) {
                _ = try await transport.acceptServerFinished(tampered, trustedNow: trustedNow)
            }
            await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState) {
                _ = try await transport.acceptServerFinished(s2Wire, trustedNow: trustedNow)
            }
        }

        let c3BeforeS2 = try OwnerSiteA2TransportKATSupport.hexData(kat.c3_wire_hex, "C3_wire")
        let wrongDirection = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
        await #expect(throws: OwnerSiteA2TransportError.authenticationFailed) {
            _ = try await wrongDirection.acceptServerFinished(c3BeforeS2, trustedNow: trustedNow)
        }
        await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState) {
            _ = try await wrongDirection.acceptServerFinished(s2Wire, trustedNow: trustedNow)
        }
    }

    @Test func everyFrozenC3WireByteTamperFailsClosed() throws {
        let kat = try OwnerSiteA2TransportKATSupport.load()
        let replay = try OwnerSiteA2TransportKATSupport.replayNoiseXX(kat)
        let c3Wire = try OwnerSiteA2TransportKATSupport.hexData(kat.c3_wire_hex, "C3_wire")

        // Keep the positive inverse next to the per-byte negative loop: this
        // covers the canonical CBOR envelope, ciphertext, and AEAD tag under
        // the frozen D→E Split key.
        _ = try OwnerSiteA2TransportKATSupport.decryptClientFinishedAck(
            c3Wire,
            chainingKey: replay.chainingKey
        )

        for index in c3Wire.indices {
            var tampered = c3Wire
            tampered[index] ^= 0x01
            #expect(throws: Error.self, "C3_wire byte \(index) must reject") {
                _ = try OwnerSiteA2TransportKATSupport.decryptClientFinishedAck(
                    tampered,
                    chainingKey: replay.chainingKey
                )
            }
        }
    }

    @Test func canonicalityBoundsAndReplayAreTerminal() async throws {
        let kat = try OwnerSiteA2TransportKATSupport.load()
        let preFinished = try OwnerSiteA2TransportKATSupport.completedPreFinished(kat)
        let s2Wire = try OwnerSiteA2TransportKATSupport.hexData(kat.s2_wire_hex, "S2_wire")
        let trustedNow = OwnerSiteA2TrustedUTC.syntheticTestOnly(
            unixSeconds: kat.channel_context.kat_now_unix_s
        )

        #expect(s2Wire.first == 0x82)
        var nonCanonicalEnvelope = Data([0x98, 0x02])
        nonCanonicalEnvelope.append(s2Wire.dropFirst())
        let nonCanonical = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
        await #expect(throws: OwnerSiteA2TransportError.nonCanonicalEnvelope) {
            _ = try await nonCanonical.acceptServerFinished(nonCanonicalEnvelope, trustedNow: trustedNow)
        }
        await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState) {
            _ = try await nonCanonical.acceptServerFinished(s2Wire, trustedNow: trustedNow)
        }

        let canonicalS2Plaintext = try OwnerSiteA2TransportKATSupport.makeServerFinishedPlaintext(kat: kat)
        #expect(canonicalS2Plaintext.first == 0x8E)
        var nonCanonicalPlaintext = Data([0x98, 0x0E])
        nonCanonicalPlaintext.append(canonicalS2Plaintext.dropFirst())
        let nonCanonicalPlaintextWire = try OwnerSiteA2TransportKATSupport.sealServerFinishedPlaintext(
            nonCanonicalPlaintext,
            chainingKey: try OwnerSiteA2TransportKATSupport.replayNoiseXX(kat).chainingKey
        )
        let nonCanonicalRecord = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
        await #expect(throws: OwnerSiteA2TransportError.nonCanonicalRecord) {
            _ = try await nonCanonicalRecord.acceptServerFinished(nonCanonicalPlaintextWire, trustedNow: trustedNow)
        }
        await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState) {
            _ = try await nonCanonicalRecord.acceptServerFinished(s2Wire, trustedNow: trustedNow)
        }

        let oversized = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
        await #expect(throws: OwnerSiteA2TransportError.invalidEnvelope) {
            _ = try await oversized.acceptServerFinished(
                Data(repeating: 0, count: OwnerSiteA2TransportProfile.maximumEnvelopeBytes + 1),
                trustedNow: trustedNow
            )
        }

        let replay = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
        _ = try await replay.acceptServerFinished(s2Wire, trustedNow: trustedNow)
        await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState) {
            _ = try await replay.acceptServerFinished(s2Wire, trustedNow: trustedNow)
        }
    }

    @Test func authenticatedS2MismatchesAndStaleLeaseFailClosed() async throws {
        let kat = try OwnerSiteA2TransportKATSupport.load()
        let replay = try OwnerSiteA2TransportKATSupport.replayNoiseXX(kat)
        let preFinished = try OwnerSiteA2TransportKATSupport.completedPreFinished(kat)
        let trustedNow = OwnerSiteA2TrustedUTC.syntheticTestOnly(
            unixSeconds: kat.channel_context.kat_now_unix_s
        )
        let correctS2 = try OwnerSiteA2TransportKATSupport.hexData(kat.s2_wire_hex, "S2_wire")

        let mismatches: [(String, (inout [HouseholdCBORValue]) -> Void)] = [
            ("domain", { $0[0] = .text("not-a2") }),
            ("version", { $0[1] = .unsigned(2) }),
            ("kind", { $0[2] = .unsigned(OwnerSiteA2RecordKind.clientFinishedAck.rawValue) }),
            ("direction", { $0[3] = .unsigned(OwnerSiteA2RecordDirection.deviceToEngine.rawValue) }),
            ("sequence", { $0[4] = .unsigned(1) }),
            ("channel id", { $0[5] = .bytes(Data(repeating: 0xA2, count: 32)) }),
            ("channel epoch", { $0[6] = .unsigned(kat.channel_context.channel_epoch + 1) }),
            ("handshake hash", { $0[7] = .bytes(Data(repeating: 0xA3, count: 32)) }),
            ("channel binding", { $0[8] = .bytes(Data(repeating: 0xA4, count: 32)) }),
            ("binding", { $0[9] = .bytes(Data(repeating: 0xA5, count: 32)) }),
            ("binding digest", { $0[10] = .bytes(Data(repeating: 0xA6, count: 32)) }),
            ("authz epoch", { $0[11] = .unsigned(kat.channel_context.authz_epoch + 1) }),
            ("roster digest", { $0[12] = .bytes(Data(repeating: 0xA7, count: 32)) }),
            ("fresh until", { $0[13] = .unsigned(kat.channel_context.fresh_until_unix_s + 1) }),
            ("binding type", { $0[9] = .text("not-a-bstr") }),
            ("binding length", { $0[9] = .bytes(Data(repeating: 0xA8, count: 31)) }),
        ]

        for (label, mutate) in mismatches {
            let wrongS2 = try OwnerSiteA2TransportKATSupport.makeServerFinishedWire(
                kat: kat,
                chainingKey: replay.chainingKey,
                mutate: mutate
            )
            let transport = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
            await #expect(throws: OwnerSiteA2TransportError.serverFinishedMismatch, "\(label)") {
                _ = try await transport.acceptServerFinished(wrongS2, trustedNow: trustedNow)
            }
            await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState, "\(label) remains terminal") {
                _ = try await transport.acceptServerFinished(correctS2, trustedNow: trustedNow)
            }
        }

        let wrongArity = try OwnerSiteA2TransportKATSupport.makeServerFinishedWire(
            kat: kat,
            chainingKey: replay.chainingKey
        ) { $0.removeLast() }
        let malformedShape = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
        await #expect(throws: OwnerSiteA2TransportError.serverFinishedMismatch) {
            _ = try await malformedShape.acceptServerFinished(wrongArity, trustedNow: trustedNow)
        }
        await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState) {
            _ = try await malformedShape.acceptServerFinished(correctS2, trustedNow: trustedNow)
        }

        let stale = OwnerSiteA2DeviceFinishedTransport(validatedPreFinished: preFinished)
        await #expect(throws: OwnerSiteA2TransportError.staleServerFinished) {
            _ = try await stale.acceptServerFinished(
                correctS2,
                trustedNow: .syntheticTestOnly(unixSeconds: kat.channel_context.fresh_until_unix_s)
            )
        }
        await #expect(throws: OwnerSiteA2TransportError.unexpectedRecordState) {
            _ = try await stale.acceptServerFinished(correctS2, trustedNow: trustedNow)
        }
    }
}
