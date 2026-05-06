import Foundation
import Testing
@testable import SoyehtCore

@Suite("PairDeviceQR")
struct PairDeviceQRTests {
    @Test func parsesValidPairDeviceURL() throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100
        """))

        let qr = try PairDeviceQR(url: url, now: now)

        #expect(qr.version == 1)
        #expect(qr.householdPublicKey == hhPub)
        #expect(qr.nonce == nonce)
        #expect(qr.householdId == (try HouseholdIdentifiers.householdIdentifier(for: hhPub)))
    }

    @Test func rejectsExpiredURLBeforeNetworkAction() throws {
        let hhPub = HouseholdTestFixtures.publicKey()
        let nonce = HouseholdTestFixtures.nonce()
        let url = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=10"))

        do {
            _ = try PairDeviceQR(url: url, now: Date(timeIntervalSince1970: 11))
            Issue.record("Expected expired QR")
        } catch PairDeviceQRError.expired {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsUnsupportedSchemeAndMalformedKey() throws {
        let badScheme = try #require(URL(string: "theyos://household/pair-device?v=1"))
        do {
            _ = try PairDeviceQR(url: badScheme)
            Issue.record("Expected unsupported scheme")
        } catch PairDeviceQRError.unsupportedScheme {
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        let nonce = HouseholdTestFixtures.nonce()
        let badKey = Data([0x04] + Array(repeating: 1, count: 32)).soyehtBase64URLEncodedString()
        let badKeyURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(badKey)&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=9999999999"))
        do {
            _ = try PairDeviceQR(url: badKeyURL)
            Issue.record("Expected invalid key")
        } catch PairDeviceQRError.invalidHouseholdPublicKey {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsUnknownCriticalField() throws {
        let hhPub = HouseholdTestFixtures.publicKey()
        let nonce = HouseholdTestFixtures.nonce()
        let url = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=9999999999&crit=future_required"))

        do {
            _ = try PairDeviceQR(url: url)
            Issue.record("Expected critical field rejection")
        } catch PairDeviceQRError.unsupportedCriticalField("future_required") {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
