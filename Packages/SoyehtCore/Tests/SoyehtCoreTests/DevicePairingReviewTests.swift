import Foundation
import CryptoKit
import Testing
@testable import SoyehtCore

@Suite("Device pairing review")
struct DevicePairingReviewTests {
    @Test func bothPeersDeriveTheSameCodeAndNamesCannotSubstituteForKeys() throws {
        let household = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let device = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let other = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        func review(_ id: String, _ key: Data, _ name: String) throws -> DevicePairingReview {
            try DevicePairingReview(requestID: id, devicePublicKey: key, deviceName: name,
                platform: "ios", expiresAt: 1_900_000_000, householdPublicKey: household)
        }
        let phone = try review("request-one", device, "Test iPhone")
        let mac = try review("request-one", device, "Test iPhone")
        #expect(phone.words.count == 6)
        #expect(phone.diagnostic == mac.diagnostic)
        #expect(phone.words != (try review("request-one", other, "Test iPhone")).words)
        #expect(phone.words != (try review("request-two", device, "Test iPhone")).words)
        #expect(phone.words == (try review("request-one", device, "Changed name")).words)
        #expect(!phone.diagnostic.contains("request-one"))
        #expect(!phone.diagnostic.contains("Test iPhone"))
    }
}
