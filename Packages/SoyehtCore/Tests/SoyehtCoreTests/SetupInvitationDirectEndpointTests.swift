import Foundation
import XCTest
@testable import SoyehtCore

final class SetupInvitationDirectEndpointTests: XCTestCase {
    func test_directEndpointPayloadRoundTrips() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x42, count: 32))
        let apns = Data([0x01, 0x02, 0x03, 0x04])
        let deviceID = UUID()
        let payload = SetupInvitationPayload(
            token: token,
            ownerDisplayName: "Alex",
            expiresAt: UInt64(Date().timeIntervalSince1970) + 3600,
            iphoneApnsToken: apns,
            iphoneDeviceID: deviceID,
            iphoneDeviceName: "Alex's iPhone",
            iphoneDeviceModel: "iPhone14,4"
        )

        let decoded = try SetupInvitationPayload.decodeDirectEndpointData(
            payload.directEndpointData()
        )

        XCTAssertEqual(decoded.token, token)
        XCTAssertEqual(decoded.ownerDisplayName, "Alex")
        XCTAssertEqual(decoded.expiresAt, payload.expiresAt)
        XCTAssertEqual(decoded.iphoneApnsToken, apns)
        XCTAssertEqual(decoded.iphoneDeviceID, deviceID)
        XCTAssertEqual(decoded.iphoneDeviceName, "Alex's iPhone")
        XCTAssertEqual(decoded.iphoneDeviceModel, "iPhone14,4")
    }

    func test_directClaimPayloadRoundTripsMacEngineURL() throws {
        let url = URL(string: "http://macstudio.tail295ab5.ts.net:8091")!
        let decoded = try SetupInvitationDirectClaim.decode(
            try SetupInvitationDirectClaim(macEngineURL: url).encodedData()
        )

        XCTAssertEqual(decoded.macEngineURL, url)
    }

    func test_directClaimPayloadRoundTripsLocalMacPairing() throws {
        let url = URL(string: "http://macstudio.tail295ab5.ts.net:8091")!
        let macID = UUID()
        let secret = Data(repeating: 0xA5, count: 32)
        let pairing = SetupInvitationMacLocalPairing(
            macID: macID,
            macName: "Mac Studio",
            host: "macstudio.tail295ab5.ts.net",
            presencePort: 49321,
            attachPort: 49322,
            secret: secret
        )

        let decoded = try SetupInvitationDirectClaim.decode(
            try SetupInvitationDirectClaim(
                macEngineURL: url,
                macLocalPairing: pairing
            ).encodedData()
        )

        XCTAssertEqual(decoded.macEngineURL, url)
        XCTAssertEqual(decoded.macLocalPairing, pairing)
    }

    func test_verifyPayloadEchoesTokenForEngineCallback() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x32, count: 32))
        let payload = SetupInvitationPayload(
            token: token,
            ownerDisplayName: nil,
            expiresAt: 1_778_559_686,
            iphoneApnsToken: nil
        )

        guard case .map(let map) = try HouseholdCBOR.decode(payload.verifyData()) else {
            return XCTFail("Expected CBOR map")
        }

        XCTAssertEqual(map["token"], .bytes(token.bytes))
        XCTAssertEqual(map["expires_at"], .unsigned(1_778_559_686))
    }

    func test_txtRecordIncludesEngineCacheFields() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x41, count: 32))
        let payload = SetupInvitationPayload(
            token: token,
            ownerDisplayName: nil,
            expiresAt: 1_778_559_686,
            iphoneApnsToken: nil
        )

        let fields = try payload.txtRecordFields()

        XCTAssertEqual(fields["v"], "1")
        XCTAssertEqual(fields["token"], PairingCrypto.base64URLEncode(token.bytes))
        XCTAssertEqual(fields["expires_at"], "1778559686")
        XCTAssertEqual(fields["owner_display_name"], "")
        XCTAssertNotNil(fields["m"])
    }

    func test_claimRequestIncludesIPhoneVerificationEndpoint() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x77, count: 32))
        let endpoint = URL(string: "http://iphone-13-mini.tail295ab5.ts.net:8092")!
        let body = SetupInvitationClaimClient.encodeRequest(
            token: token,
            ownerDisplayName: nil,
            iphoneApnsToken: nil,
            iphoneEndpoint: endpoint,
            iphoneAddresses: ["100.66.202.16"],
            expiresAt: 1_778_559_686
        )

        guard case .map(let map) = try HouseholdCBOR.decode(body) else {
            return XCTFail("Expected CBOR map")
        }

        XCTAssertEqual(map["token"], .bytes(token.bytes))
        XCTAssertEqual(map["iphone_endpoint"], .text(endpoint.absoluteString))
        XCTAssertEqual(map["iphone_addrs"], .array([.text("100.66.202.16")]))
        XCTAssertEqual(map["expires_at"], .unsigned(1_778_559_686))
    }

    func test_claimClientAcceptsEngineAckShape() async throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x21, count: 32))
        let responseBody = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "iphone_endpoint": .text("iphone-13-mini.local.:8092"),
            "owner_display_name": .text(""),
            "hh_id": .null,
        ]))
        let client = SetupInvitationClaimClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { request in
                XCTAssertEqual(request.url?.path, "/bootstrap/claim-setup-invitation")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/cbor"]
                )!
                return (responseBody, response)
            }
        )

        let acceptedAt = try await client.claim(
            token: token,
            ownerDisplayName: nil,
            iphoneApnsToken: nil
        )

        XCTAssertEqual(acceptedAt, 0)
    }
}
