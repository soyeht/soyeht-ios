import XCTest
@testable import SoyehtCore

final class BootstrapInitializeClientTests: XCTestCase {
    func test_decodesCurrentEngineResponseWithMetadataFields() async throws {
        let hhPub = Data(repeating: 0x02, count: 33)
        let initResponse = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "hh_id": .text("hh_test"),
            "hh_pub": .bytes(hhPub),
            "pair_qr_uri": .text("soyeht://household/pair-device?t=test"),
            "name": .text("Test Home"),
            "created_at": .unsigned(1_778_505_448),
        ]))
        // `BootstrapInitializeClient` now runs an `EngineCompat` pre-flight
        // handshake that hits `/bootstrap/status` before the main POST. The
        // shared transport closure needs to route both paths — initialize
        // body vs a minimal status body that reports a supported engine.
        let statusResponse = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "state": .text("uninitialized"),
            "engine_version": .text(EngineCompat.minSupportedEngineVersion),
            "platform": .text("mac"),
            "host_label": .text("Mac"),
            "device_count": .unsigned(0),
            "owner_display_name": .null,
            "hh_id": .null,
            "hh_pub": .null,
        ]))
        let client = BootstrapInitializeClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { request in
                let path = request.url?.path ?? ""
                if path == BootstrapStatusClient.path {
                    return (statusResponse, makeInitializeHTTPResponse(statusCode: 200))
                }
                return (initResponse, makeInitializeHTTPResponse(statusCode: 200))
            }
        )

        let result = try await client.initialize(name: "Test Home", claimToken: nil)

        XCTAssertEqual(result.hhId, "hh_test")
        XCTAssertEqual(result.hhPub, hhPub)
        XCTAssertEqual(result.pairQrUri, "soyeht://household/pair-device?t=test")
    }

    func test_bootstrapErrorDescriptionsAreUserReadable() {
        XCTAssertEqual(
            BootstrapError.serverError(code: "already_initialized", message: nil).localizedDescription,
            "Soyeht is already set up on this Mac."
        )
        XCTAssertEqual(
            BootstrapError.protocolViolation(detail: .missingRequiredField).localizedDescription,
            "Soyeht returned an incomplete response."
        )
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
