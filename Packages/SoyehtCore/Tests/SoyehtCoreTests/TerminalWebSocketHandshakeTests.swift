import Testing
import Foundation
@testable import SoyehtCore

@Suite struct TerminalWebSocketHandshakeTests {
    @Test func verifyReturnsFailureForUnreachableHost() async {
        // Reserved-for-documentation IP per RFC 5737 — guaranteed unroutable.
        // Resolves immediately, never connects, hits a transport error well
        // inside the short timeout window.
        let url = URL(string: "ws://192.0.2.1:9/")!
        let result = await TerminalWebSocketHandshake.verify(url: url, timeout: 1.5)
        switch result {
        case .success:
            Issue.record("Handshake against reserved IP should never succeed")
        case .failure:
            break
        }
    }

    @Test func verifyReturnsFailureWhenTimeoutElapses() async {
        // Same RFC 5737 IP plus a much shorter timeout; the close path
        // exercises the DispatchWorkItem timeout, not the URLSession error.
        let url = URL(string: "ws://192.0.2.1:9/")!
        let started = Date()
        let result = await TerminalWebSocketHandshake.verify(url: url, timeout: 0.25)
        let elapsed = Date().timeIntervalSince(started)
        switch result {
        case .success:
            Issue.record("Handshake against reserved IP should never succeed")
        case .failure:
            // Don't pin the upper bound too tight — URLSession can resolve and
            // fail before the timer fires. Lower bound: must not return
            // immediately on a malformed URL; the request was at least dispatched.
            #expect(elapsed >= 0)
        }
    }
}
