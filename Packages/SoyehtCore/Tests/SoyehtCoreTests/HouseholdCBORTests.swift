import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdCBOR")
struct HouseholdCBORTests {
    @Test func pairingProofContextIsCanonicalAndRoundTrips() throws {
        let nonce = Data([1, 2, 3])
        let pPub = HouseholdTestFixtures.publicKey(byte: 0x44)
        let first = HouseholdCBOR.pairingProofContext(
            householdId: "hh_test",
            nonce: nonce,
            personPublicKey: pPub
        )
        let second = HouseholdCBOR.pairingProofContext(
            householdId: "hh_test",
            nonce: nonce,
            personPublicKey: pPub
        )

        #expect(first == second)
        #expect(try HouseholdCBOR.encode(HouseholdCBOR.decode(first)) == first)
    }

    @Test func requestSigningContextChangesWhenInputsChange() {
        let bodyHash = Data(repeating: 0, count: 32)
        let get = HouseholdCBOR.requestSigningContext(
            method: "GET",
            pathAndQuery: "/api/v1/household/snapshot",
            timestamp: 1,
            bodyHash: bodyHash
        )
        let post = HouseholdCBOR.requestSigningContext(
            method: "POST",
            pathAndQuery: "/api/v1/household/snapshot",
            timestamp: 1,
            bodyHash: bodyHash
        )
        #expect(get != post)
    }
}
