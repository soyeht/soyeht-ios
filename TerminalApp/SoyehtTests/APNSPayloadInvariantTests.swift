import XCTest
@testable import Soyeht

final class APNSPayloadInvariantTests: XCTestCase {
    func testCanonicalPayloadBytesAreExactlyTheContractLiteral() throws {
        let expected = try XCTUnwrap(#"{"aps":{"content-available":1}}"#.data(using: .utf8))

        XCTAssertEqual(APNSOpaqueTickle.canonicalPayloadBytes, expected)
        XCTAssertNoThrow(try APNSOpaqueTickle.validatePayloadBytes(expected))
    }

    func testCanonicalPayloadRejectsLengthWhitespaceAndExtraKeys() throws {
        let payloads = [
            #"{"v":1}"#,
            #"{"aps": {"content-available":1}}"#,
            #"{"aps":{"content-available":1},"hh_id":"hh_test"}"#,
            #"{"aps":{"content-available":1,"mutable-content":1}}"#
        ]

        for payload in payloads {
            let data = try XCTUnwrap(payload.data(using: .utf8))
            XCTAssertThrowsError(try APNSOpaqueTickle.validatePayloadBytes(data)) { error in
                XCTAssertEqual(error as? APNSOpaqueTickleError, .payloadBytesNotCanonical)
            }
        }
    }

    func testRuntimeUserInfoAllowsOnlyOpaqueBackgroundTickle() {
        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1]
        ]

        XCTAssertNoThrow(try APNSOpaqueTickle.validateUserInfo(payload))
    }

    func testRuntimeUserInfoRejectsHouseholdDataFields() {
        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "hh_id": "hh_test"
        ]

        XCTAssertThrowsError(try APNSOpaqueTickle.validateUserInfo(payload)) { error in
            XCTAssertEqual(error as? APNSOpaqueTickleError, .forbiddenPayloadKey("hh_id"))
        }
    }

    func testRuntimeUserInfoRejectsAPNSAlertBadgeSoundAndMutableContent() {
        let payloads: [(payload: [AnyHashable: Any], key: String)] = [
            (["aps": ["content-available": 1, "alert": "Join request"]], "aps.alert"),
            (["aps": ["content-available": 1, "badge": 1]], "aps.badge"),
            (["aps": ["content-available": 1, "sound": "default"]], "aps.sound"),
            (["aps": ["content-available": 1, "mutable-content": 1]], "aps.mutable-content")
        ]

        for item in payloads {
            XCTAssertThrowsError(try APNSOpaqueTickle.validateUserInfo(item.payload)) { error in
                XCTAssertEqual(error as? APNSOpaqueTickleError, .forbiddenPayloadKey(item.key))
            }
        }
    }
}
