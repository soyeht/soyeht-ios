import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdIdentifiers")
struct HouseholdIdentifiersTests {
    @Test func base64URLRoundTripsWithoutPadding() throws {
        let data = Data([0xfb, 0xff, 0xee, 0x00])
        let encoded = data.soyehtBase64URLEncodedString()
        #expect(encoded == "-__uAA")
        #expect(try Data(soyehtBase64URL: encoded) == data)
    }

    @Test func base32UsesLowercaseNoPadding() {
        #expect(HouseholdIdentifiers.base32LowerNoPadding(Data([0xf0])) == "6a")
    }

    @Test func identifierValidatesCompressedP256PublicKey() throws {
        let key = HouseholdTestFixtures.publicKey(byte: 0x11)
        let id = try HouseholdIdentifiers.householdIdentifier(for: key)
        #expect(id.hasPrefix("hh_"))
        #expect(id.count == 55)
    }

    @Test func identifierRejectsInvalidCompressedKeyPrefix() {
        do {
            _ = try HouseholdIdentifiers.personIdentifier(for: HouseholdTestFixtures.publicKey(prefix: 0x04))
            Issue.record("Expected invalid prefix")
        } catch HouseholdIdentifierError.invalidCompressedP256Prefix(0x04) {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func identifierRejectsCompressedKeyThatIsNotOnP256Curve() {
        do {
            _ = try HouseholdIdentifiers.personIdentifier(for: Data([0x02]) + Data(repeating: 0xff, count: 32))
            Issue.record("Expected invalid P-256 point")
        } catch HouseholdIdentifierError.invalidCompressedP256Point {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
