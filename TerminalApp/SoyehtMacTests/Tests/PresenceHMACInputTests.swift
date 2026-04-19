import XCTest
import Foundation
@testable import SoyehtMacDomain
import SoyehtCore

/// Pure-data tests for the presence HMAC helper extracted in PR #4 to
/// collapse the duplicated byte layout that used to live inline in both
/// `MacPresenceClient` (iPhone) and `PresenceSession` (Mac).
///
/// Byte order is part of the wire contract — both sides MUST agree or the
/// handshake fails silently. These tests pin the layout to:
///   [serverNonce] ++ [clientNonce] ++ [lowercased-deviceID.utf8]
final class PresenceHMACInputTests: XCTestCase {

    func testParts_layoutIsServerNonceThenClientNonceThenLowercasedDeviceID() {
        let serverNonce = Data([0x11, 0x22, 0x33])
        let clientNonce = Data([0xAA, 0xBB])
        let deviceID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!

        let parts = PresenceHMACInput.parts(
            serverNonce: serverNonce,
            clientNonce: clientNonce,
            deviceID: deviceID
        )

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], serverNonce)
        XCTAssertEqual(parts[1], clientNonce)
        XCTAssertEqual(parts[2], Data("deadbeef-0000-0000-0000-000000000001".utf8),
                       "deviceID must be lowercased (case normalization prevents Mac/iPhone mismatch)")
    }

    func testParts_isDeterministicForFixedInputs() {
        let serverNonce = Data(repeating: 0x01, count: 16)
        let clientNonce = Data(repeating: 0x02, count: 16)
        let deviceID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

        let a = PresenceHMACInput.parts(serverNonce: serverNonce, clientNonce: clientNonce, deviceID: deviceID)
        let b = PresenceHMACInput.parts(serverNonce: serverNonce, clientNonce: clientNonce, deviceID: deviceID)
        XCTAssertEqual(a, b)
    }

    func testParts_uppercaseAndLowercaseUUIDsProduceSameBytes() {
        let serverNonce = Data([0x01])
        let clientNonce = Data([0x02])
        let upper = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let lower = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!

        let a = PresenceHMACInput.parts(serverNonce: serverNonce, clientNonce: clientNonce, deviceID: upper)
        let b = PresenceHMACInput.parts(serverNonce: serverNonce, clientNonce: clientNonce, deviceID: lower)
        XCTAssertEqual(a, b, "case of the source UUID must not affect output bytes")
    }
}
