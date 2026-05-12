import XCTest
@testable import SoyehtCore

final class BootstrapTeardownClientTests: XCTestCase {
    func test_noHouseholdToTeardownConflict_surfacesStableErrorCode() async {
        let response = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "error": .text("no_household_to_teardown"),
            "state": .text("uninitialized"),
        ]))
        let client = BootstrapTeardownClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { _ in (response, makeTeardownHTTPResponse(statusCode: 409)) }
        )

        do {
            try await client.teardown()
            XCTFail("expected server error")
        } catch BootstrapError.serverError(let code, _) {
            XCTAssertEqual(code, "no_household_to_teardown")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private func makeTeardownHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:8091/bootstrap/teardown")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/cbor"]
    )!
}
