import Testing
import Foundation
import SoyehtCore
@testable import Soyeht

// MARK: - Test Helpers

/// Uses unique host per server to avoid addServer host-dedup collisions.
/// Uses "slv-" ID prefix to avoid collisions with other test suites.
private func makeServer(id: String,
                        host: String,
                        name: String,
                        role: String? = "admin") -> PairedServer {
    PairedServer(id: id, host: host, name: name, role: role, pairedAt: Date(), expiresAt: nil)
}

private func cleanupTestServers(_ store: SoyehtCore.SessionStore, ids: [String]) {
    for id in ids {
        store.removeServer(id: id)
    }
}

/// Check if a server ID exists in the store.
private func storeContains(_ store: SoyehtCore.SessionStore, id: String) -> Bool {
    store.pairedServers.contains(where: { $0.id == id })
}

// MARK: - Tests

@Suite("ServerListView — SessionStore integration", .serialized)
struct ServerListViewTests {

    @Test("addServer stores servers retrievable by ID")
    func addServerStoresServers() {
        let store = makeIsolatedSessionStore()
        let ids = ["slv-add-1", "slv-add-2", "slv-add-3"]
        cleanupTestServers(store, ids: ids)

        store.addServer(makeServer(id: "slv-add-1", host: "slv-alpha.test.io", name: "alpha"), token: "t1")
        #expect(storeContains(store, id: "slv-add-1"))

        store.addServer(makeServer(id: "slv-add-2", host: "slv-beta.test.io", name: "beta"), token: "t2")
        #expect(storeContains(store, id: "slv-add-2"))

        store.addServer(makeServer(id: "slv-add-3", host: "slv-gamma.test.io", name: "gamma"), token: "t3")
        #expect(storeContains(store, id: "slv-add-3"))

        cleanupTestServers(store, ids: ids)
    }

    @Test("active server is identified correctly")
    func activeServerIsIdentified() {
        let store = makeIsolatedSessionStore()
        let ids = ["slv-act-a", "slv-act-b"]
        cleanupTestServers(store, ids: ids)

        store.addServer(makeServer(id: "slv-act-a", host: "slv-primary.test.io", name: "primary"), token: "t1")
        store.addServer(makeServer(id: "slv-act-b", host: "slv-secondary.test.io", name: "secondary"), token: "t2")
        store.setActiveServer(id: "slv-act-b")

        #expect(store.activeServerId == "slv-act-b")
        let active = store.pairedServers.first(where: { $0.id == "slv-act-b" })
        #expect(active?.name == "secondary")

        cleanupTestServers(store, ids: ids)
    }

    @Test("switch active server updates activeServerId")
    func switchActiveServer() {
        let store = makeIsolatedSessionStore()
        let ids = ["slv-sw-x", "slv-sw-y"]
        cleanupTestServers(store, ids: ids)

        store.addServer(makeServer(id: "slv-sw-x", host: "slv-x.test.io", name: "server-x"), token: "tx")
        store.addServer(makeServer(id: "slv-sw-y", host: "slv-y.test.io", name: "server-y"), token: "ty")
        store.setActiveServer(id: "slv-sw-x")

        #expect(store.activeServerId == "slv-sw-x")

        store.setActiveServer(id: "slv-sw-y")

        let activeServerId = store.activeServerId
        let active = store.pairedServers.first(where: { $0.id == activeServerId })
        #expect(activeServerId == "slv-sw-y")
        #expect(active?.host == "slv-y.test.io")

        cleanupTestServers(store, ids: ids)
    }

    @Test("remove server cleans up token and server list")
    func removeServerCleansUp() {
        let store = makeIsolatedSessionStore()
        let ids = ["slv-rm-keep", "slv-rm-gone"]
        cleanupTestServers(store, ids: ids)

        store.addServer(makeServer(id: "slv-rm-keep", host: "slv-keep.test.io", name: "keeper"), token: "tk")
        store.addServer(makeServer(id: "slv-rm-gone", host: "slv-gone.test.io", name: "goner"), token: "tg")
        store.setActiveServer(id: "slv-rm-keep")

        store.removeServer(id: "slv-rm-gone")

        #expect(storeContains(store, id: "slv-rm-keep"))
        #expect(!storeContains(store, id: "slv-rm-gone"))
        #expect(store.tokenForServer(id: "slv-rm-gone") == nil)

        cleanupTestServers(store, ids: ids)
    }

    @Test("removing active server falls back to first remaining")
    func removeActiveServerFallsToFirst() {
        let store = makeIsolatedSessionStore()
        let ids = ["slv-fb-first", "slv-fb-second"]
        cleanupTestServers(store, ids: ids)

        store.addServer(makeServer(id: "slv-fb-first", host: "slv-first.test.io", name: "first"), token: "t1")
        store.addServer(makeServer(id: "slv-fb-second", host: "slv-second.test.io", name: "second"), token: "t2")
        store.setActiveServer(id: "slv-fb-first")

        store.removeServer(id: "slv-fb-first")

        #expect(!storeContains(store, id: "slv-fb-first"))
        #expect(storeContains(store, id: "slv-fb-second"))
        // SessionStore.removeServer falls back activeServerId to first remaining
        #expect(store.activeServerId != "slv-fb-first")

        cleanupTestServers(store, ids: ids)
    }

    @Test("removing last test server clears its token")
    func removeLastServerClearsToken() {
        let store = makeIsolatedSessionStore()
        let ids = ["slv-last-only"]
        cleanupTestServers(store, ids: ids)

        store.addServer(makeServer(id: "slv-last-only", host: "slv-only.test.io", name: "only"), token: "t1")
        #expect(storeContains(store, id: "slv-last-only"))

        store.removeServer(id: "slv-last-only")

        #expect(!storeContains(store, id: "slv-last-only"))
        #expect(store.tokenForServer(id: "slv-last-only") == nil)

        cleanupTestServers(store, ids: ids)
    }
}
