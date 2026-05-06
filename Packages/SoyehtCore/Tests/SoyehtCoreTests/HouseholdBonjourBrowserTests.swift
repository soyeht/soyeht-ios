import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdBonjourBrowser")
struct HouseholdBonjourBrowserTests {
    @Test func candidateMatchesHouseholdIdOpenPairingAndShortNonce() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x61)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x62)
        let qr = PairDeviceQR(
            version: 1,
            householdPublicKey: hhPub,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            nonce: nonce,
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        let candidate = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://casa.local:8443")!,
            householdId: qr.householdId,
            householdName: "Casa Caio",
            machineId: "m_mac",
            pairingState: "open",
            shortNonce: qr.shortNonce
        )

        #expect(candidate.matches(qr: qr))
    }

    @Test func candidateRejectsMismatchedHouseholdAndNonce() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x63)
        let qr = PairDeviceQR(
            version: 1,
            householdPublicKey: hhPub,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            nonce: HouseholdTestFixtures.nonce(byte: 0x64),
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        let wrongHousehold = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://other.local:8443")!,
            householdId: "hh_other",
            householdName: "Other",
            machineId: nil,
            pairingState: "open",
            shortNonce: qr.shortNonce
        )
        let wrongNonce = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://casa.local:8443")!,
            householdId: qr.householdId,
            householdName: "Casa Caio",
            machineId: nil,
            pairingState: "open",
            shortNonce: "different"
        )

        #expect(!wrongHousehold.matches(qr: qr))
        #expect(!wrongNonce.matches(qr: qr))
    }
}
