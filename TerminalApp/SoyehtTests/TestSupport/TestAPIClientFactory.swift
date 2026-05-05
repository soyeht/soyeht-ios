import Foundation
@testable import Soyeht

func makeTestClient() -> SoyehtAPIClient {
    let store = makeIsolatedSessionStore()
    let server = PairedServer(
        id: "test-server-original",
        host: "test.example.com",
        name: "test",
        role: "admin",
        pairedAt: Date(),
        expiresAt: nil
    )
    store.addServer(server, token: "test-token-123")
    store.setActiveServer(id: server.id)
    return SoyehtAPIClient(session: makeTestSession(), store: store)
}
