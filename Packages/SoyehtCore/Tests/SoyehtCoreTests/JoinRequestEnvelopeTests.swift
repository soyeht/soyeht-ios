import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("JoinRequestEnvelope")
struct JoinRequestEnvelopeTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func qr(
        hostname: String = "studio.local",
        platform: PairMachinePlatform = .macos,
        transport: PairMachineTransport = .tailscale
    ) throws -> PairMachineQR {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let mPub = key.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xAB, count: 32)
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: hostname,
            platform: platform.rawValue
        )
        let signature = try key.signature(for: challenge).rawRepresentation
        return PairMachineQR(
            version: 1,
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: hostname,
            platform: platform,
            transport: transport,
            address: "100.64.1.5:8443",
            challengeSignature: signature,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    @Test func buildsFromQRPreservingAllSignedFields() throws {
        let qr = try Self.qr()
        let envelope = JoinRequestEnvelope(from: qr, householdId: "hh_test", receivedAt: Self.now)

        #expect(envelope.householdId == "hh_test")
        #expect(envelope.machinePublicKey == qr.machinePublicKey)
        #expect(envelope.nonce == qr.nonce)
        #expect(envelope.rawHostname == qr.hostname)
        #expect(envelope.rawPlatform == qr.platform.rawValue)
        #expect(envelope.candidateAddress == qr.address)
        #expect(envelope.ttlUnix == UInt64(qr.expiresAt.timeIntervalSince1970))
        #expect(envelope.challengeSignature == qr.challengeSignature)
        #expect(envelope.transportOrigin == .qrTailscale)
        #expect(envelope.receivedAt == Self.now)
    }

    @Test func transportOriginFromQRMapsToCorrectCase() throws {
        let lanQR = try Self.qr(transport: .lan)
        let tailscaleQR = try Self.qr(transport: .tailscale)

        let lanEnvelope = JoinRequestEnvelope(from: lanQR, householdId: "hh_x", receivedAt: Self.now)
        let tailscaleEnvelope = JoinRequestEnvelope(from: tailscaleQR, householdId: "hh_x", receivedAt: Self.now)

        #expect(lanEnvelope.transportOrigin == .qrLAN)
        #expect(tailscaleEnvelope.transportOrigin == .qrTailscale)
    }

    @Test func idempotencyKeyIsStableForSameTuple() throws {
        let qr = try Self.qr()
        let envelopeA = JoinRequestEnvelope(from: qr, householdId: "hh_a", receivedAt: Self.now)
        let envelopeB = JoinRequestEnvelope(from: qr, householdId: "hh_a", receivedAt: Self.now.addingTimeInterval(60))
        #expect(envelopeA.idempotencyKey == envelopeB.idempotencyKey)
    }

    @Test func idempotencyKeyDiffersWhenAnyComponentDiffers() throws {
        let qrOne = try Self.qr()
        let envelopeBaseline = JoinRequestEnvelope(from: qrOne, householdId: "hh_a", receivedAt: Self.now)
        let envelopeOtherHH = JoinRequestEnvelope(from: qrOne, householdId: "hh_b", receivedAt: Self.now)
        let envelopeOtherHostname = JoinRequestEnvelope(from: try Self.qr(hostname: "other.local"), householdId: "hh_a", receivedAt: Self.now)

        // Different household → different key
        #expect(envelopeBaseline.idempotencyKey != envelopeOtherHH.idempotencyKey)
        // Same key triple (hh_id, m_pub, nonce) → same key, regardless of hostname change
        // (Tampered hostname wouldn't actually pass FR-029 — this just locks the
        // policy that the key is keyed by the binding triple, not by display data.)
        #expect(envelopeBaseline.idempotencyKey == envelopeOtherHostname.idempotencyKey)
    }

    @Test func displayHostnameRoutesThroughSafeRenderer() {
        let envelope = JoinRequestEnvelope(
            householdId: "hh_a",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            nonce: Data(repeating: 0x01, count: 32),
            rawHostname: "studio\u{202E}exe.gpj\u{0007}",
            rawPlatform: "macos",
            candidateAddress: "x",
            ttlUnix: 1_000,
            challengeSignature: Data(repeating: 0, count: 64),
            transportOrigin: .qrTailscale,
            receivedAt: Self.now
        )
        let displayed = envelope.displayHostname()
        #expect(!displayed.unicodeScalars.contains("\u{202E}"))
        #expect(!displayed.unicodeScalars.contains("\u{0007}"))
        #expect(displayed.contains("studio"))
    }

    @Test func displayPlatformRoutesThroughSafeRenderer() {
        let envelope = JoinRequestEnvelope(
            householdId: "hh_a",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            nonce: Data(repeating: 0x01, count: 32),
            rawHostname: "host",
            rawPlatform: "macos\u{0000}\u{202E}",
            candidateAddress: "x",
            ttlUnix: 1_000,
            challengeSignature: Data(repeating: 0, count: 64),
            transportOrigin: .qrTailscale,
            receivedAt: Self.now
        )
        let displayed = envelope.displayPlatform()
        #expect(!displayed.unicodeScalars.contains("\u{0000}"))
        #expect(!displayed.unicodeScalars.contains("\u{202E}"))
        #expect(displayed.hasPrefix("macos"))
    }

    @Test func displayAccessorsAreIdempotentUnderRepeatedRendering() {
        let envelope = JoinRequestEnvelope(
            householdId: "hh_a",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            nonce: Data(repeating: 0x01, count: 32),
            rawHostname: "this-host\u{202E}tries-to-attack-with-a-long-suffix-that-must-be-truncated",
            rawPlatform: "macos",
            candidateAddress: "x",
            ttlUnix: 1_000,
            challengeSignature: Data(repeating: 0, count: 64),
            transportOrigin: .qrTailscale,
            receivedAt: Self.now
        )
        let renderer = JoinRequestSafeRenderer()
        let once = envelope.displayHostname(maxCharacters: 24)
        let twice = renderer.render(once, maxCharacters: 24)
        #expect(once == twice)
        #expect(once.count <= 24)
    }

    @Test func displayHostnameAppliesLengthCapAndPreservesTrustworthyPrefix() {
        let envelope = JoinRequestEnvelope(
            householdId: "hh_a",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            nonce: Data(repeating: 0x01, count: 32),
            rawHostname: "trustworthy-prefix-then-attacker-suffix-many-many-chars-here-yes",
            rawPlatform: "macos",
            candidateAddress: "x",
            ttlUnix: 1_000,
            challengeSignature: Data(repeating: 0, count: 64),
            transportOrigin: .qrTailscale,
            receivedAt: Self.now
        )
        let displayed = envelope.displayHostname(maxCharacters: 24)
        #expect(displayed.count == 24)
        #expect(displayed.hasPrefix("trustworthy-prefix"))
        #expect(displayed.hasSuffix("…"))
    }

    @Test func isExpiredReportsTrueAtAndPastTTL() {
        let envelope = JoinRequestEnvelope(
            householdId: "hh_a",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            nonce: Data(repeating: 0x01, count: 32),
            rawHostname: "x",
            rawPlatform: "macos",
            candidateAddress: "x",
            ttlUnix: UInt64(Self.now.timeIntervalSince1970),
            challengeSignature: Data(repeating: 0, count: 64),
            transportOrigin: .qrTailscale,
            receivedAt: Self.now.addingTimeInterval(-60)
        )
        #expect(envelope.isExpired(now: Self.now))
        #expect(envelope.isExpired(now: Self.now.addingTimeInterval(1)))
        #expect(!envelope.isExpired(now: Self.now.addingTimeInterval(-1)))
    }
}
