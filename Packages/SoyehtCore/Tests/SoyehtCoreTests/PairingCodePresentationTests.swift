import Foundation
import Testing
@testable import SoyehtCore

/// The Mac and the iPhone show a code to be compared by eye. If the two ends
/// derive it differently — or if one of them derives it from a link the other
/// is not using — the comparison is theatre.
@Suite("PairingCodePresentation")
struct PairingCodePresentationTests {
    private let hhPub = HouseholdTestFixtures.publicKey(byte: 0x41)
    private let nonce = HouseholdTestFixtures.nonce(byte: 0x42)
    private let now = Date(timeIntervalSince1970: 1_714_972_800)

    private func pairDeviceURL(ttl: UInt64 = 1_714_973_100) throws -> URL {
        try #require(URL(string:
            "soyeht://household/pair-device?v=1"
            + "&hh_pub=\(hhPub.soyehtBase64URLEncodedString())"
            + "&nonce=\(nonce.soyehtBase64URLEncodedString())"
            + "&ttl=\(ttl)"
            + "&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())"
            + "&crit=m_cert_fp"
        ))
    }

    private func devicePairingURL() throws -> URL {
        try HouseholdDevicePairingLink(
            endpoint: try #require(URL(string: "http://100.64.0.2:8101")),
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            householdPublicKey: hhPub,
            householdName: "Sample Home",
            pairingNonce: nonce
        ).url()
    }

    @Test func bothLinkShapesAgreeOnTheSameSixWords() throws {
        let fromEngineLink = try PairingCodePresentation.words(pairingURL: pairDeviceURL(), now: now)
        let fromMacLink = try PairingCodePresentation.words(pairingURL: devicePairingURL(), now: now)

        #expect(fromEngineLink.count == 6)
        #expect(fromEngineLink == fromMacLink)
    }

    @Test func theWordsAreTheFingerprintsOwnWordsNotAPrefix() throws {
        let words = try PairingCodePresentation.words(pairingURL: pairDeviceURL(), now: now)
        let fingerprint = try OperatorFingerprint.derive(
            machinePublicKey: hhPub,
            pairingNonce: nonce,
            wordlist: try BIP39Wordlist()
        )

        #expect(words == fingerprint.words)
        #expect(PairingCodePresentation.wordCount == OperatorFingerprint.wordCount)
    }

    @Test func anEngineLinkPastItsWindowIsRefusedRatherThanShown() throws {
        let url = try pairDeviceURL(ttl: 1_714_972_000)

        #expect(throws: PairingCodePresentation.Failure.expired) {
            _ = try PairingCodePresentation.words(pairingURL: url, now: now)
        }
    }

    @Test func aMacMintedLinkHasNoWindowToOutlive() throws {
        let url = try devicePairingURL()
        let farFuture = Date(timeIntervalSince1970: 4_000_000_000)

        #expect(try PairingCodePresentation.words(pairingURL: url, now: farFuture).count == 6)
    }

    @Test func somethingThatIsNotAPairingLinkSaysSo() throws {
        let url = try #require(URL(string: "soyeht://household/join?token=abc"))

        #expect(throws: PairingCodePresentation.Failure.unrecognizedLink) {
            _ = try PairingCodePresentation.words(pairingURL: url, now: now)
        }
        #expect(throws: PairingCodePresentation.Failure.unrecognizedLink) {
            _ = try PairingCodePresentation.words(pairingURI: "not a url at all %%", now: now)
        }
    }

    @Test func aDifferentNonceGivesDifferentWordsForTheSameHouse() throws {
        let other = try HouseholdDevicePairingLink(
            endpoint: try #require(URL(string: "http://100.64.0.2:8101")),
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            householdPublicKey: hhPub,
            householdName: "Sample Home",
            pairingNonce: HouseholdTestFixtures.nonce(byte: 0x43)
        ).url()

        let first = try PairingCodePresentation.words(pairingURL: devicePairingURL(), now: now)
        let second = try PairingCodePresentation.words(pairingURL: other, now: now)

        #expect(first != second, "this is why two minters cannot both be live")
    }
}
