import XCTest
@testable import SoyehtCore

final class BootstrapPairDeviceURIClientTests: XCTestCase {
    func test_decodesPairDeviceURIResponse() async throws {
        let hhPub = Data(repeating: 0x02, count: 33)
        let pairURI = "soyeht://household/pair-device?v=1&hh_pub=test&nonce=test&ttl=9999999999"
        let response = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "house_name": .text("HomeStudio"),
            "host_label": .text("Mac Studio"),
            "hh_id": .text("hh_test"),
            "hh_pub": .bytes(hhPub),
            "pair_device_uri": .text(pairURI),
            "expires_at": .unsigned(1_778_600_000),
        ]))
        let client = BootstrapPairDeviceURIClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { request in
                XCTAssertEqual(request.url?.path, "/bootstrap/pair-device-uri")
                return (response, makePairDeviceURIHTTPResponse(statusCode: 200))
            }
        )

        let result = try await client.fetch()

        XCTAssertEqual(result.houseName, "HomeStudio")
        XCTAssertEqual(result.hostLabel, "Mac Studio")
        XCTAssertEqual(result.hhId, "hh_test")
        XCTAssertEqual(result.hhPub, hhPub)
        XCTAssertEqual(result.pairDeviceURI, pairURI)
        XCTAssertEqual(result.expiresAt, 1_778_600_000)
    }

    func test_rejectsMalformedPublicKey() async {
        let response = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "house_name": .text("HomeStudio"),
            "host_label": .text("Mac Studio"),
            "hh_id": .text("hh_test"),
            "hh_pub": .bytes(Data(repeating: 0x02, count: 32)),
            "pair_device_uri": .text("soyeht://household/pair-device?v=1"),
        ]))
        let client = BootstrapPairDeviceURIClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { _ in (response, makePairDeviceURIHTTPResponse(statusCode: 200)) }
        )

        do {
            _ = try await client.fetch()
            XCTFail("expected malformed response to throw")
        } catch BootstrapError.protocolViolation(let detail) {
            XCTAssertEqual(detail, .unexpectedResponseShape)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private func makePairDeviceURIHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:8091/bootstrap/pair-device-uri")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/cbor"]
    )!
}
