import CryptoKit
import Foundation
import XCTest

@testable import SoyehtCore

final class NostrNIP44Tests: XCTestCase {
    func testOfficialVectorEncryptMatches() throws {
        let conversationKey = try XCTUnwrap(Data(
            soyehtHex: "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"
        ))
        let nonce = try XCTUnwrap(Data(
            soyehtHex: "0000000000000000000000000000000000000000000000000000000000000001"
        ))
        let expectedBase64 =
            "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"

        let actual = try NostrNIP44.encryptWithConversationKey(
            plaintext: Data("a".utf8),
            conversationKey: conversationKey,
            nonce: nonce
        )

        XCTAssertEqual(actual, expectedBase64)
    }

    func testChaCha20OfficialBlockMatches() throws {
        let key = try XCTUnwrap(Data(
            soyehtHex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        ))
        let nonce = try XCTUnwrap(Data(soyehtHex: "000000090000004a00000000"))
        let expected = try XCTUnwrap(Data(
            soyehtHex: "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e"
        ))

        let actual = try NostrChaCha20.encrypt(
            key: key,
            nonce: nonce,
            counter: 1,
            plaintext: Data(repeating: 0, count: 64)
        )

        XCTAssertEqual(actual, expected)
    }
}
