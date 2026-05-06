import XCTest
import SoyehtCore
@testable import Soyeht

@MainActor
final class HouseholdPairingViewModelTests: XCTestCase {
    func testScanToActiveHouseholdState() async throws {
        let household = makeHouseholdState(name: "Casa Caio")
        let viewModel = HouseholdPairingViewModel { _ in household }

        await viewModel.pairNow(url: URL(string: "soyeht://household/pair-device?v=1")!)

        XCTAssertEqual(viewModel.state, .paired(household))
    }

    func testFailureStateDoesNotActivateHousehold() async throws {
        let viewModel = HouseholdPairingViewModel { _ in
            throw HouseholdPairingError.noMatchingHousehold
        }

        await viewModel.pairNow(url: URL(string: "soyeht://household/pair-device?v=1")!)

        XCTAssertEqual(viewModel.state, .failed(.noMatchingHousehold))
    }

    private func makeHouseholdState(name: String) -> ActiveHouseholdState {
        let publicKey = Data([0x02]) + Data(repeating: 1, count: 32)
        let cert = PersonCert(
            rawCBOR: Data([1, 2, 3]),
            version: 1,
            type: "person",
            householdId: "hh_test",
            personId: "p_test",
            personPublicKey: publicKey,
            displayName: "Caio",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) }.sorted { $0.operation < $1.operation },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: "hh:hh_test",
            signature: Data(repeating: 0, count: 64)
        )
        return ActiveHouseholdState(
            householdId: "hh_test",
            householdName: name,
            householdPublicKey: publicKey,
            endpoint: URL(string: "https://casa.local:8443")!,
            ownerPersonId: "p_test",
            ownerPublicKey: publicKey,
            ownerKeyReference: "owner-key",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 2),
            lastSeenAt: nil
        )
    }
}
