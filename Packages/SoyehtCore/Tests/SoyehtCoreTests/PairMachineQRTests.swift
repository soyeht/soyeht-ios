import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("PairMachineQR")
struct PairMachineQRTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let defaultTTLSeconds: TimeInterval = 300

    private static func privateKey(seed: UInt8 = 0x42) -> P256.Signing.PrivateKey {
        try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    }

    private struct OverrideKnobs {
        var omitFields: Set<String> = []
        var versionInQR: String = "1"
        var mPubInQR: String? = nil          // override base64url payload
        var hostnameInQR: String? = nil
        var platformInQR: String? = nil
        var transportInQR: String? = nil
        var addressInQR: String? = nil
        var challengeSigInQR: String? = nil
        var ttlInQR: String? = nil
        var nonceInQR: String? = nil
    }

    private static func makeURL(
        privateKey: P256.Signing.PrivateKey,
        nonce: Data = Data(repeating: 0xAB, count: 32),
        hostname: String = "studio.local",
        platform: PairMachinePlatform = .macos,
        transport: PairMachineTransport = .tailscale,
        address: String = "100.64.1.5:8443",
        ttlOffsetSeconds: TimeInterval = defaultTTLSeconds,
        overrideMachinePublicKey: Data? = nil,
        signedHostname: String? = nil,
        signedPlatform: String? = nil,
        knobs: OverrideKnobs = .init()
    ) -> URL {
        let mPub = overrideMachinePublicKey ?? privateKey.publicKey.compressedRepresentation
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: signedHostname ?? hostname,
            platform: signedPlatform ?? platform.rawValue
        )
        let signature = try! privateKey.signature(for: challenge).rawRepresentation
        let expiry = now.addingTimeInterval(ttlOffsetSeconds).timeIntervalSince1970

        let candidates: [(String, String)] = [
            ("v", knobs.versionInQR),
            ("m_pub", knobs.mPubInQR ?? mPub.soyehtBase64URLEncodedString()),
            ("nonce", knobs.nonceInQR ?? nonce.soyehtBase64URLEncodedString()),
            ("hostname", knobs.hostnameInQR ?? hostname),
            ("platform", knobs.platformInQR ?? platform.rawValue),
            ("transport", knobs.transportInQR ?? transport.rawValue),
            ("addr", knobs.addressInQR ?? address),
            ("challenge_sig", knobs.challengeSigInQR ?? signature.soyehtBase64URLEncodedString()),
            ("ttl", knobs.ttlInQR ?? String(Int(expiry))),
        ]

        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-machine"
        components.queryItems = candidates
            .filter { !knobs.omitFields.contains($0.0) }
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    @Test func parsesAValidSignedQR() throws {
        let key = Self.privateKey()
        let url = Self.makeURL(privateKey: key)
        let qr = try PairMachineQR(url: url, now: Self.now)

        #expect(qr.version == 1)
        #expect(qr.machinePublicKey == key.publicKey.compressedRepresentation)
        #expect(qr.hostname == "studio.local")
        #expect(qr.platform == .macos)
        #expect(qr.transport == .tailscale)
        #expect(qr.address == "100.64.1.5:8443")
        #expect(qr.challengeSignature.count == 64)
        #expect(qr.expiresAt > Self.now)
    }

    @Test func rejectsUnsupportedScheme() {
        let key = Self.privateKey()
        let url = Self.makeURL(privateKey: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "https"
        #expect(throws: PairMachineQRError.unsupportedScheme) {
            try PairMachineQR(url: components.url!, now: Self.now)
        }
    }

    @Test func rejectsUnsupportedPath() {
        let key = Self.privateKey()
        let url = Self.makeURL(privateKey: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = "/pair-device"
        #expect(throws: PairMachineQRError.unsupportedPath) {
            try PairMachineQR(url: components.url!, now: Self.now)
        }
    }

    @Test func rejectsExpiredQR() {
        let key = Self.privateKey()
        let url = Self.makeURL(privateKey: key, ttlOffsetSeconds: -10)  // ttl in the past
        #expect(throws: PairMachineQRError.expired) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsUnsupportedVersion() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(versionInQR: "2")
        )
        #expect(throws: PairMachineQRError.unsupportedVersion("2")) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsMissingMandatoryFields() throws {
        let key = Self.privateKey()
        let mandatoryFields = ["v", "m_pub", "nonce", "hostname", "platform", "transport", "addr", "challenge_sig", "ttl"]
        for field in mandatoryFields {
            let url = Self.makeURL(privateKey: key, knobs: .init(omitFields: [field]))
            do {
                _ = try PairMachineQR(url: url, now: Self.now)
                Issue.record("Expected missingField(\(field)) to throw, got success")
            } catch PairMachineQRError.missingField(let name) {
                #expect(name == field)
            } catch {
                Issue.record("Expected missingField(\(field)), got \(error)")
            }
        }
    }

    @Test func rejectsUnsupportedPlatform() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(platformInQR: "windows")
        )
        #expect(throws: PairMachineQRError.unsupportedPlatform("windows")) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsUnsupportedTransport() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(transportInQR: "bluetooth")
        )
        #expect(throws: PairMachineQRError.unsupportedTransport("bluetooth")) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsTamperedHostnameAsAntiPhishing() {
        // The candidate signed hostname="studio.local"; an attacker-rewritten
        // QR carries hostname="evil.local" but reuses the original signature.
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            hostname: "studio.local",
            knobs: .init(hostnameInQR: "evil.local")
        )
        #expect(throws: PairMachineQRError.challengeSignatureVerificationFailed) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsTamperedPlatformAsAntiPhishing() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            platform: .macos,
            knobs: .init(platformInQR: "linux-nix")
        )
        #expect(throws: PairMachineQRError.challengeSignatureVerificationFailed) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsSignatureProducedByDifferentKey() {
        // Attacker signs a JoinChallenge with their own key but embeds the
        // legitimate candidate's m_pub. The signature MUST fail verification.
        let candidateKey = Self.privateKey(seed: 0x01)
        let candidatePub = candidateKey.publicKey.compressedRepresentation
        let attackerKey = Self.privateKey(seed: 0x02)
        let url = Self.makeURL(
            privateKey: attackerKey,
            overrideMachinePublicKey: candidatePub
        )
        #expect(throws: PairMachineQRError.challengeSignatureVerificationFailed) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsInvalidChallengeSignatureLength() {
        let key = Self.privateKey()
        let badSignature = Data(repeating: 0xAA, count: 32)  // wrong length
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(challengeSigInQR: badSignature.soyehtBase64URLEncodedString())
        )
        #expect(throws: PairMachineQRError.invalidChallengeSignatureLength(32)) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsInvalidChallengeSignatureEncoding() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(challengeSigInQR: "not!valid!base64url")
        )
        do {
            _ = try PairMachineQR(url: url, now: Self.now)
            Issue.record("Expected invalidChallengeSignatureEncoding")
        } catch PairMachineQRError.invalidChallengeSignatureEncoding {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsInvalidMachinePublicKey() {
        let key = Self.privateKey()
        let badKey = Data(repeating: 0xFF, count: 33)  // not on the curve
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(mPubInQR: badKey.soyehtBase64URLEncodedString())
        )
        #expect(throws: PairMachineQRError.invalidMachinePublicKey) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsEmptyNonce() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(nonceInQR: "")
        )
        #expect(throws: PairMachineQRError.invalidNonce) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func rejectsInvalidExpiry() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(ttlInQR: "not-a-number")
        )
        #expect(throws: PairMachineQRError.invalidExpiry) {
            try PairMachineQR(url: url, now: Self.now)
        }
    }

    @Test func acceptsAllSupportedPlatformAndTransportCombinations() throws {
        let key = Self.privateKey()
        for platform in PairMachinePlatform.allCases {
            for transport in PairMachineTransport.allCases {
                let url = Self.makeURL(
                    privateKey: key,
                    platform: platform,
                    transport: transport
                )
                let qr = try PairMachineQR(url: url, now: Self.now)
                #expect(qr.platform == platform)
                #expect(qr.transport == transport)
            }
        }
    }

    @Test func percentEncodedHostnameRoundTripsThroughSignatureVerification() throws {
        let key = Self.privateKey()
        let hostname = "café.studio.local"
        let url = Self.makeURL(privateKey: key, hostname: hostname)
        let qr = try PairMachineQR(url: url, now: Self.now)
        #expect(qr.hostname == hostname)
    }

    /// Defends against the FR-012 hard-TTL bypass via the candidate's
    /// install-time signature: `ttl` is NOT inside the signed `JoinChallenge`,
    /// so an attacker rewriting `ttl` to a far-future timestamp would still
    /// satisfy challenge verification. The local cap bounds the practical
    /// replay window to the spec's 5-minute hard TTL regardless of QR claims.
    @Test func rejectsTTLExceedingMaxAllowedWindow() {
        let key = Self.privateKey()
        // Set ttl 1 hour in the future — far above the 300s max.
        let url = Self.makeURL(privateKey: key, ttlOffsetSeconds: 3_600)
        do {
            _ = try PairMachineQR(url: url, now: Self.now)
            Issue.record("Expected ttlExceedsMaxAllowed")
        } catch let PairMachineQRError.ttlExceedsMaxAllowed(seconds, max) {
            #expect(seconds == 3_600)
            #expect(max == 300)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func acceptsTTLAtTheConfiguredMaxBoundary() throws {
        let key = Self.privateKey()
        // Exactly 300s in the future — at the boundary, accepted.
        let url = Self.makeURL(privateKey: key, ttlOffsetSeconds: 300)
        let qr = try PairMachineQR(url: url, now: Self.now)
        #expect(qr.expiresAt == Self.now.addingTimeInterval(300))
    }

    @Test func customMaxTTLOverrideTightensTheCap() {
        let key = Self.privateKey()
        // Cap to 60s; 120s in the future MUST be rejected even though it
        // is below the spec's 300s default.
        let url = Self.makeURL(privateKey: key, ttlOffsetSeconds: 120)
        do {
            _ = try PairMachineQR(url: url, now: Self.now, maxTTLSeconds: 60)
            Issue.record("Expected ttlExceedsMaxAllowed under tighter cap")
        } catch PairMachineQRError.ttlExceedsMaxAllowed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    /// Distinguishes raw base64url decode failure from the empty-payload case.
    @Test func malformedNonceEncodingSurfacesDistinctError() {
        let key = Self.privateKey()
        let url = Self.makeURL(
            privateKey: key,
            knobs: .init(nonceInQR: "not!base64!")
        )
        do {
            _ = try PairMachineQR(url: url, now: Self.now)
            Issue.record("Expected invalidNonceEncoding")
        } catch PairMachineQRError.invalidNonceEncoding {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
