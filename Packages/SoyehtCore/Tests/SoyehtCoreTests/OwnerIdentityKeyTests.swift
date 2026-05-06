import Foundation
import Testing
@testable import SoyehtCore

@Suite("OwnerIdentityKey")
struct OwnerIdentityKeyTests {
    @Test func inMemoryOwnerIdentitySignsWithInjectedSigner() throws {
        let publicKey = HouseholdTestFixtures.publicKey(byte: 0x55)
        let key = try InMemoryOwnerIdentityKey(publicKey: publicKey) { payload in
            Data(payload.reversed())
        }

        #expect(key.publicKey == publicKey)
        #expect(key.personId == (try HouseholdIdentifiers.personIdentifier(for: publicKey)))
        #expect(try key.sign(Data([1, 2, 3])) == Data([3, 2, 1]))
    }

    @Test func derSignatureConvertsToRawP256Signature() throws {
        let r = Data(repeating: 0x11, count: 32)
        let s = Data(repeating: 0x22, count: 32)
        let der = Data([0x30, 0x44, 0x02, 0x20]) + r + Data([0x02, 0x20]) + s
        #expect(try OwnerIdentityKey.rawP256Signature(fromDER: der) == r + s)
    }
}
