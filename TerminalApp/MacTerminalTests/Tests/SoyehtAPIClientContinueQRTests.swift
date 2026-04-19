import XCTest
import Foundation
import SoyehtCore

/// Regression tests for PR#4 Blocker 3 — the legacy fallback in
/// `generateContinueQR` (route: `/api/v1/mobile/continue-qr`) has been
/// deleted. Non-2xx responses must now propagate as `APIError.httpError`
/// directly; they must NOT trigger a second request to the legacy
/// `/api/v1/instances/<id>/qr-token` endpoint.
///
/// The assertion that "no fallback fires" is enforced by counting
/// intercepted requests: the old path would have issued at least one extra
/// call (to `getInstances` or `qr-token`) whereas the new path issues
/// exactly one — the original continue-qr POST.
final class SoyehtAPIClientContinueQRTests: XCTestCase {

    override func tearDown() async throws {
        ContinueQRMockProtocol.reset()
        try await super.tearDown()
    }

    func test_generateContinueQR_404_propagatesHttpError_noFallback() async throws {
        ContinueQRMockProtocol.configure(statusCode: 404, body: Data(#"{"error":"not_found"}"#.utf8))
        let (client, _) = try makeClient()

        var caught: Error?
        do {
            _ = try await client.generateContinueQR(container: "c1", workspaceId: "ws-1")
            XCTFail("Expected APIError.httpError(404, _) to be thrown")
        } catch {
            caught = error
        }

        XCTAssertEqual(ContinueQRMockProtocol.recordedPaths, ["/api/v1/mobile/continue-qr"],
                       "Only the continue-qr endpoint may be hit — legacy fallback must be gone")
        if let apiError = caught as? SoyehtAPIClient.APIError,
           case .httpError(let code, _) = apiError {
            XCTAssertEqual(code, 404)
        } else {
            XCTFail("Expected APIError.httpError(404, _), got \(String(describing: caught))")
        }
    }

    func test_generateContinueQR_405_propagatesHttpError_noFallback() async throws {
        ContinueQRMockProtocol.configure(statusCode: 405, body: Data(#"{"error":"method_not_allowed"}"#.utf8))
        let (client, _) = try makeClient()

        var caught: Error?
        do {
            _ = try await client.generateContinueQR(container: "c1", workspaceId: "ws-1")
            XCTFail("Expected APIError.httpError(405, _) to be thrown")
        } catch {
            caught = error
        }

        XCTAssertEqual(ContinueQRMockProtocol.recordedPaths, ["/api/v1/mobile/continue-qr"])
        if let apiError = caught as? SoyehtAPIClient.APIError,
           case .httpError(let code, _) = apiError {
            XCTAssertEqual(code, 405)
        } else {
            XCTFail("Expected APIError.httpError(405, _), got \(String(describing: caught))")
        }
    }

    // MARK: - Helpers

    private func makeClient() throws -> (SoyehtAPIClient, SessionStore) {
        let suiteName = "soyeht.tests.continueQR.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SessionStore(
            defaults: defaults,
            keychainService: "com.soyeht.tests.\(UUID().uuidString)"
        )
        let server = PairedServer(
            id: "test-server",
            host: "api.example.com",
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil
        )
        store.addServer(server, token: "test-token")
        store.setActiveServer(id: server.id)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContinueQRMockProtocol.self]
        let session = URLSession(configuration: config)
        let client = SoyehtAPIClient(session: session, store: store)
        return (client, store)
    }
}

// MARK: - Mock URLProtocol

/// Records every intercepted request path, then responds with a configured
/// status code + body. Reset between tests.
final class ContinueQRMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var body: Data = Data()
    nonisolated(unsafe) private static var paths: [String] = []

    static func configure(statusCode: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        self.statusCode = statusCode
        self.body = body
        self.paths = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        statusCode = 200
        body = Data()
        paths = []
    }

    static var recordedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ContinueQRMockProtocol.lock.lock()
        let status = ContinueQRMockProtocol.statusCode
        let payload = ContinueQRMockProtocol.body
        if let path = request.url?.path {
            ContinueQRMockProtocol.paths.append(path)
        }
        ContinueQRMockProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
