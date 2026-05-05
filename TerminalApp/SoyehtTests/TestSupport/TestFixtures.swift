import Foundation
@testable import Soyeht

/// Default context paired with `makeTestClient()` above - same host/token
/// so existing per-request assertions keep working verbatim.
func makeTestServerContext() -> ServerContext {
    let server = PairedServer(
        id: "test-server-original",
        host: "test.example.com",
        name: "test",
        role: "admin",
        pairedAt: Date(),
        expiresAt: nil
    )
    return ServerContext(server: server, token: "test-token-123")
}

let workspaceJSON = """
{"workspace":{"id":"ws-1","sessionId":"ws-1","displayName":"","container":"test","status":"active"}}
"""
