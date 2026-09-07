import Foundation
import Testing
@testable import SoyehtCore

private final class TerminalFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        // Encode each case in its own URL: concurrent tests share no mutable
        // response handler and never contact a real engine or Keychain.
        let code = request.url!.lastPathComponent
        if code == "intents" {
            let status = request.url!.path.contains("legacy-route") ? 404 : 405
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"code\":\"\(code)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct LocalTerminalFailureTests {
    @Test @MainActor func identicalHTTPStatusDoesNotMakeEveryFailureRetryable() async throws {
        let name = "com.soyeht.core.tests.terminal-failures.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SessionStore(defaults: defaults, credentialStorage: InMemoryHouseholdStorage())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TerminalFailureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SoyehtAPIClient(session: session, store: store)
        let server = PairedServer(id: "test-engine", host: "engine.example.test", name: "Test engine", role: "admin", pairedAt: Date(), expiresAt: nil, platform: "macos", kind: .engine)
        let context = ServerContext(server: store.addServer(server, token: "TOKEN_EXAMPLE"), token: "TOKEN_EXAMPLE")
        let cases: [(String, SoyehtAPIClient.LocalTerminalFailure)] = [
            ("supervisor_unavailable", .unavailable),
            ("supervisor_protocol_mismatch", .incompatibleProtocol),
            ("future_unknown_error", .rejected(code: "future_unknown_error")),
            ("instance_mismatch", .instanceMismatch),
            ("intent_consumed", .intentExpired),
            ("intent_expired", .intentExpired),
            ("session_closed", .sessionEnded),
        ]
        for (code, expected) in cases {
            do {
                _ = try await client.getLocalTerminal(conversationId: code, context: context)
                Issue.record("Error response was accepted")
            } catch let error as SoyehtAPIClient.LocalTerminalFailure {
                #expect(error == expected)
            }
        }
        for conversation in ["legacy-route", "legacy-method"] {
            do {
                _ = try await client.issueLocalTerminalIntent(conversationId: conversation, context: context)
                Issue.record("Missing issuance route was accepted")
            } catch let error as SoyehtAPIClient.LocalTerminalFailure {
                #expect(error == .incompatibleProtocol)
            }
        }
    }
}
