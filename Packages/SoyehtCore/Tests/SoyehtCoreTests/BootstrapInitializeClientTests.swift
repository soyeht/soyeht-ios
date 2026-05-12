import XCTest
@testable import SoyehtCore

final class BootstrapInitializeClientTests: XCTestCase {
    func test_decodesCurrentEngineResponseWithMetadataFields() async throws {
        let hhPub = Data(repeating: 0x02, count: 33)
        let response = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "hh_id": .text("hh_test"),
            "hh_pub": .bytes(hhPub),
            "pair_qr_uri": .text("soyeht://household/pair-device?t=test"),
            "name": .text("Test Home"),
            "created_at": .unsigned(1_778_505_448),
        ]))
        let client = BootstrapInitializeClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { _ in (response, makeInitializeHTTPResponse(statusCode: 200)) }
        )

        let result = try await client.initialize(name: "Test Home", claimToken: nil)

        XCTAssertEqual(result.hhId, "hh_test")
        XCTAssertEqual(result.hhPub, hhPub)
        XCTAssertEqual(result.pairQrUri, "soyeht://household/pair-device?t=test")
    }
}

private func makeInitializeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:8091/bootstrap/initialize")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/cbor"]
    )!
}
