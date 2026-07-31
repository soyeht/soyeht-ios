import Foundation
import Testing
@testable import SoyehtCore

@Suite("PairDeviceQR")
struct PairDeviceQRTests {
    @Test func parsesValidPairDeviceURL() throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let fp = Data(repeating: 0xAB, count: 32)
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&house_name=Sample%20Home&host=192.0.2.10:8101&m_cert_fp=\(fp.soyehtBase64URLEncodedString())&crit=m_cert_fp
        """))

        let qr = try PairDeviceQR(url: url, now: now)

        #expect(qr.version == 1)
        #expect(qr.householdPublicKey == hhPub)
        #expect(qr.nonce == nonce)
        #expect(qr.householdId == (try HouseholdIdentifiers.householdIdentifier(for: hhPub)))
        #expect(qr.householdName == "Sample Home")
        #expect(qr.hostFallback == "192.0.2.10:8101")
        #expect(qr.machineCertFingerprint == fp)
    }

    @Test func rejectsExpiredURLBeforeNetworkAction() throws {
        let hhPub = HouseholdTestFixtures.publicKey()
        let nonce = HouseholdTestFixtures.nonce()
        let fp = Data(repeating: 0xAB, count: 32)
        let url = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=10&m_cert_fp=\(fp.soyehtBase64URLEncodedString())&crit=m_cert_fp"))

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
        let fp = Data(repeating: 0xAB, count: 32)
        let badKey = Data([0x04] + Array(repeating: 1, count: 32)).soyehtBase64URLEncodedString()
        let badKeyURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(badKey)&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=9999999999&m_cert_fp=\(fp.soyehtBase64URLEncodedString())&crit=m_cert_fp"))
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

    @Test func parsesMCertFpValid() throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let fp = Data(repeating: 0xAB, count: 32)
        let fpB64 = fp.soyehtBase64URLEncodedString()
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(fpB64)&crit=m_cert_fp
        """))

        let qr = try PairDeviceQR(url: url, now: now)
        #expect(qr.machineCertFingerprint == fp)
    }

    @Test func rejectsMCertFpDuplicate() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let fp = Data(repeating: 0xAB, count: 32)
        let fpB64 = fp.soyehtBase64URLEncodedString()
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(fpB64)&m_cert_fp=\(fpB64)&crit=m_cert_fp
        """))

        do {
            _ = try PairDeviceQR(url: url)
            Issue.record("Expected duplicate rejection")
        } catch PairDeviceQRError.duplicateField("m_cert_fp") {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsMCertFpWithoutCrit() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let fp = Data(repeating: 0xAB, count: 32)
        let fpB64 = fp.soyehtBase64URLEncodedString()
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(fpB64)
        """))

        do {
            _ = try PairDeviceQR(url: url)
            Issue.record("Expected crit rejection")
        } catch PairDeviceQRError.invalidCriticalField {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsMCertFpWrongLength() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let fp = Data(repeating: 0xAB, count: 16)
        let fpB64 = fp.soyehtBase64URLEncodedString()
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(fpB64)&crit=m_cert_fp
        """))

        do {
            _ = try PairDeviceQR(url: url)
            Issue.record("Expected invalid fp rejection")
        } catch PairDeviceQRError.invalidMachineCertFingerprint {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsMCertFpPadded() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let fp = Data(repeating: 0xAB, count: 32)
        let fpPadded = Data(base64Encoded: fp.base64EncodedString())!
        let fpB64Padded = fpPadded.base64EncodedString()
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(fpB64Padded)&crit=m_cert_fp
        """))

        do {
            _ = try PairDeviceQR(url: url)
            Issue.record("Expected padded rejection")
        } catch PairDeviceQRError.invalidMachineCertFingerprint {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsCritWithMultipleFields() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let fp = Data(repeating: 0xAB, count: 32)
        let fpB64 = fp.soyehtBase64URLEncodedString()
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(fpB64)&crit=m_cert_fp,host
        """))

        do {
            _ = try PairDeviceQR(url: url)
            Issue.record("Expected crit value rejection")
        } catch PairDeviceQRError.invalidCriticalField {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func rejectsMissingMCertFpWithValidCrit() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x22)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x33)
        let url = try #require(URL(string: """
        soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=9999999999&crit=m_cert_fp
        """))

        do {
            _ = try PairDeviceQR(url: url)
            Issue.record("Expected missing m_cert_fp rejection")
        } catch PairDeviceQRError.missingField("m_cert_fp") {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
