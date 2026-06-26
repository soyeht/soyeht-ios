import Foundation
import Network
import XCTest
@testable import SoyehtCore

final class SetupInvitationDirectEndpointTests: XCTestCase {
    private let exampleMacURL = URL(string: "http://mac.example:8091")!
    private let exampleMacHost = "mac.example"
    private let exampleIPhoneURL = URL(string: "http://iphone.example:8092")!

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

    func test_iPhoneSetupInvitationFactoryPinsCanonicalTTLAndMetadata() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x24, count: 32))
        let apns = Data([0x0A, 0x0B, 0x0C])
        let deviceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let now = Date(timeIntervalSince1970: 1_800_000_000.75)

        let payload = SetupInvitationPayload.iPhoneSetupInvitation(
            token: token,
            now: now,
            iphoneApnsToken: apns,
            iphoneDeviceID: deviceID,
            iphoneDeviceName: "device-alpha",
            iphoneDeviceModel: "iPhone15,3"
        )

        XCTAssertEqual(payload.token, token)
        XCTAssertNil(payload.ownerDisplayName)
        XCTAssertEqual(payload.expiresAt, 1_800_003_600)
        XCTAssertEqual(payload.iphoneApnsToken, apns)
        XCTAssertEqual(payload.iphoneDeviceID, deviceID)
        XCTAssertEqual(payload.iphoneDeviceName, "device-alpha")
        XCTAssertEqual(payload.iphoneDeviceModel, "iPhone15,3")

        let fields = try payload.txtRecordFields()
        XCTAssertEqual(fields["expires_at"], "1800003600")
        XCTAssertEqual(fields["iphone_device_id"], deviceID.uuidString)
        XCTAssertEqual(fields["iphone_device_name"], "device-alpha")
        XCTAssertEqual(fields["iphone_device_model"], "iPhone15,3")

        let decoded = try SetupInvitationPayload.decodeDirectEndpointData(payload.directEndpointData())
        XCTAssertEqual(decoded, payload)
    }

    func test_iPhoneSetupInvitationFactoryAllowsExplicitTTLForTestsAndFutureFlows() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x25, count: 32))

        let payload = SetupInvitationPayload.iPhoneSetupInvitation(
            token: token,
            now: Date(timeIntervalSince1970: 2_000),
            ttlSeconds: 120,
            iphoneApnsToken: nil,
            iphoneDeviceID: nil,
            iphoneDeviceName: nil,
            iphoneDeviceModel: nil
        )

        XCTAssertEqual(payload.expiresAt, 2_120)
    }

    func test_setupInvitationAppCallSitesUseCoreFactory() throws {
        let appDelegate = try codeOnly(relativePath: "TerminalApp/Soyeht/AppDelegate.swift")
        let addDevicePicker = try codeOnly(relativePath: "TerminalApp/Soyeht/Home/AddDevicePickerView.swift")

        XCTAssertEqual(
            appDelegate.occurrences(of: "SetupInvitationPayload.iPhoneSetupInvitation("),
            1
        )
        XCTAssertEqual(
            addDevicePicker.occurrences(of: "SetupInvitationPayload.iPhoneSetupInvitation("),
            1
        )
        XCTAssertFalse(appDelegate.contains("expiresAt: UInt64(Date().timeIntervalSince1970) + 3600"))
        XCTAssertFalse(addDevicePicker.contains("expiresAt: UInt64(Date().timeIntervalSince1970) + 3600"))
    }

    func test_directClaimPayloadRoundTripsMacEngineURL() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x11, count: 32))
        let url = exampleMacURL
        let decoded = try SetupInvitationDirectClaim.decode(
            try SetupInvitationDirectClaim(token: token, macEngineURL: url).encodedData()
        )

        XCTAssertEqual(decoded.token, token)
        XCTAssertEqual(decoded.macEngineURL, url)
    }

    func test_directClaimPayloadRoundTripsLocalMacPairing() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x12, count: 32))
        let url = exampleMacURL
        let macID = UUID()
        let secret = Data(repeating: 0xA5, count: 32)
        let pairing = SetupInvitationMacLocalPairing(
            macID: macID,
            macName: "Mac",
            host: exampleMacHost,
            presencePort: 49321,
            attachPort: 49322,
            secret: secret
        )

        let decoded = try SetupInvitationDirectClaim.decode(
            try SetupInvitationDirectClaim(
                token: token,
                macEngineURL: url,
                macLocalPairing: pairing
            ).encodedData()
        )

        XCTAssertEqual(decoded.token, token)
        XCTAssertEqual(decoded.macEngineURL, url)
        XCTAssertEqual(decoded.macLocalPairing, pairing)
    }

    func test_directClaimPayloadRoundTripsExistingHouse() throws {
        let token = try SetupInvitationToken(bytes: Data(repeating: 0x15, count: 32))
        let url = exampleMacURL
        let house = SetupInvitationExistingHouse(
            name: "HomeStudio",
            hostLabel: "Mac Studio",
            pairDeviceURI: "soyeht://household/pair-device?v=1&hh_pub=abc&nonce=def&ttl=9999999999"
        )

        let decoded = try SetupInvitationDirectClaim.decode(
            try SetupInvitationDirectClaim(
                token: token,
                macEngineURL: url,
                existingHouse: house
            ).encodedData()
        )

        XCTAssertEqual(decoded.token, token)
        XCTAssertEqual(decoded.macEngineURL, url)
        XCTAssertEqual(decoded.existingHouse, house)
    }

    func test_directClaimRejectsTokenMismatch() throws {
        let expected = try SetupInvitationToken(bytes: Data(repeating: 0x13, count: 32))
        let supplied = try SetupInvitationToken(bytes: Data(repeating: 0x14, count: 32))
        let url = exampleMacURL
        let data = try SetupInvitationDirectClaim(
            token: supplied,
            macEngineURL: url
        ).encodedData()

        XCTAssertThrowsError(
            try SetupInvitationDirectClaim.decode(data, expectedToken: expected)
        ) { error in
            XCTAssertEqual(error as? SetupInvitationDirectError, .unauthorizedClaim)
        }
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
        let endpoint = exampleIPhoneURL
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

    func test_setupInvitationReleaseParametersAllowLocalNetworkAndTailscale() {
        let releaseParameters = NWParameters.localNetworkAndTailscale()
        XCTAssertTrue(releaseParameters.includePeerToPeer)

        let tailscaleParameters = NWParameters.tailscaleOnly()
        XCTAssertFalse(tailscaleParameters.includePeerToPeer)
    }

    private func codeOnly(relativePath: String) throws -> String {
        let source = try String(
            contentsOf: workspaceRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
        var output = ""
        var inBlockComment = false

        for line in source.components(separatedBy: .newlines) {
            var index = line.startIndex
            while index < line.endIndex {
                let rest = line[index...]
                if inBlockComment {
                    if let end = rest.range(of: "*/") {
                        index = end.upperBound
                        inBlockComment = false
                    } else {
                        index = line.endIndex
                    }
                    continue
                }
                if rest.hasPrefix("//") {
                    break
                }
                if rest.hasPrefix("/*") {
                    inBlockComment = true
                    index = line.index(index, offsetBy: 2)
                    continue
                }
                output.append(line[index])
                index = line.index(after: index)
            }
            output.append("\n")
        }
        return output
    }

    private func workspaceRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
