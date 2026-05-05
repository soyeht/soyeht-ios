import Foundation
import SoyehtCore
@testable import Soyeht

func makeTestClient() -> SoyehtCore.SoyehtAPIClient {
    let store = makeIsolatedSessionStore()
    let server = SoyehtCore.PairedServer(
        id: "test-server-original",
        host: "test.example.com",
        name: "test",
        role: "admin",
        pairedAt: Date(),
        expiresAt: nil
    )
    store.addServer(server, token: "test-token-123")
    store.setActiveServer(id: server.id)
    return SoyehtCore.SoyehtAPIClient(session: makeTestSession(), store: store)
}
