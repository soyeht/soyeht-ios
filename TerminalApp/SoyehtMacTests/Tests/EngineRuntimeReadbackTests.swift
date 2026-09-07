import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

final class EngineRuntimeReadbackTests: XCTestCase {
    func testRequestUsesOnlyTheProfilesLoopbackAdminEndpoint() throws {
        for profile in [SoyehtInstallProfile.dev, SoyehtInstallProfile.release] {
            let request = try XCTUnwrap(EngineRuntimeReadback.request(profile: profile, token: "fixture-token\n"))
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, profile.adminPort)
            XCTAssertEqual(request.url?.path, "/api/v1/version")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        }
        XCTAssertNil(EngineRuntimeReadback.request(profile: .dev, token: " \n"))
        XCTAssertNil(EngineRuntimeReadback.request(profile: .dev, token: "fixture\r\nOther: header"))
    }

    func testRedirectCannotMoveTheCredentialToAnotherEndpoint() throws {
        let request = try XCTUnwrap(EngineRuntimeReadback.request(profile: .dev, token: "fixture"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) // Never resumed.
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 302,
            httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.invalid/"]))
        var called = false
        EngineRuntimeReadback.NoRedirect().urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) { followup in
                called = true
                XCTAssertNil(followup)
            }
        XCTAssertTrue(called)
    }
}
