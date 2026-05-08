import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdBonjourBrowser")
struct HouseholdBonjourBrowserTests {
    @Test func candidateMatchesHouseholdIdDevicePairingAndShortNonce() throws {
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
            pairingState: "device",
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
            pairingState: "device",
            shortNonce: qr.shortNonce
        )
        let wrongNonce = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://casa.local:8443")!,
            householdId: qr.householdId,
            householdName: "Casa Caio",
            machineId: nil,
            pairingState: "device",
            shortNonce: "different"
        )

        #expect(!wrongHousehold.matches(qr: qr))
        #expect(!wrongNonce.matches(qr: qr))
    }

    /// A Phase 3 publisher (machine join, `pairing=machine`) must never
    /// match a Phase 2 `PairDeviceQR` even when household and nonce
    /// align. The doc-comment on `matches(qr:)` promises this exclusion;
    /// this pin closes the regression vector if a future refactor
    /// loosens the exact-string check (e.g. switches to a permissive
    /// "any non-empty pairing state" guard).
    @Test func candidateRejectsMachinePairingForDeviceQR() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x65)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x66)
        let qr = PairDeviceQR(
            version: 1,
            householdPublicKey: hhPub,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            nonce: nonce,
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        let machineCandidate = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://casa.local:8443")!,
            householdId: qr.householdId,
            householdName: "Casa Caio",
            machineId: "m_mac",
            pairingState: "machine",
            shortNonce: qr.shortNonce
        )

        #expect(!machineCandidate.matches(qr: qr))
    }
}
