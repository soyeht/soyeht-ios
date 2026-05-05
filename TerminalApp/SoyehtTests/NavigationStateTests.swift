import Testing
import Foundation
import SoyehtCore
@testable import Soyeht

@Suite("NavigationState — persistence, restore logic, and cleanup", .serialized)
struct NavigationStateTests {

    private func makeStore() -> SoyehtCore.SessionStore {
        makeIsolatedSessionStore()
    }

    // MARK: - Serialization (5 tests)

    @Test("round-trip preserves all fields")
    func roundTrip() {
        let store = makeStore()
        store.clearNavigationState()
        store.saveNavigationState(NavigationState(
            serverId: "srv-1", instanceId: "inst-1",
            sessionName: "dev", savedAt: Date()
        ))
        let loaded = store.loadNavigationState()
        #expect(loaded?.serverId == "srv-1")
        #expect(loaded?.instanceId == "inst-1")
        #expect(loaded?.sessionName == "dev")
        store.clearNavigationState()
    }

    @Test("returns nil when empty")
    func emptyReturnsNil() {
        let store = makeStore()
        store.clearNavigationState()
        #expect(store.loadNavigationState() == nil)
    }

    @Test("clear removes state")
    func clearWorks() {
        let store = makeStore()
        store.clearNavigationState()
        store.saveNavigationState(NavigationState(
            serverId: "s", instanceId: "i", sessionName: nil, savedAt: Date()
        ))
        store.clearNavigationState()
        #expect(store.loadNavigationState() == nil)
    }

    @Test("expired >24h returns nil")
    func expiredState() {
        let store = makeStore()
        store.clearNavigationState()
        store.saveNavigationState(NavigationState(
            serverId: "s", instanceId: "i", sessionName: nil,
            savedAt: Date().addingTimeInterval(-25 * 3600)
        ))
        #expect(store.loadNavigationState() == nil)
        store.clearNavigationState()
    }

    @Test("fresh <24h loads")
    func freshState() {
        let store = makeStore()
        store.clearNavigationState()
        store.saveNavigationState(NavigationState(
            serverId: "s", instanceId: "fresh", sessionName: "main",
            savedAt: Date().addingTimeInterval(-3600)
        ))
        #expect(store.loadNavigationState()?.instanceId == "fresh")
        store.clearNavigationState()
    }

    // MARK: - Restore decision logic (5 tests)

    @Test("resolve nil state → nil")
    func resolveNilState() {
        #expect(NavigationState.resolve(state: nil, activeServerId: "srv") == nil)
    }

    @Test("resolve expired → nil")
    func resolveExpired() {
        let s = NavigationState(serverId: "srv", instanceId: "i",
                                sessionName: nil,
                                savedAt: Date().addingTimeInterval(-25 * 3600))
        #expect(NavigationState.resolve(state: s, activeServerId: "srv") == nil)
    }

    @Test("resolve server mismatch → nil")
    func resolveWrongServer() {
        let s = NavigationState(serverId: "srv-A", instanceId: "i",
                                sessionName: nil, savedAt: Date())
        #expect(NavigationState.resolve(state: s, activeServerId: "srv-B") == nil)
    }

    @Test("resolve match → returns instanceId + sessionName")
    func resolveMatch() {
        let s = NavigationState(serverId: "srv", instanceId: "inst-42",
                                sessionName: "ws-1", savedAt: Date())
        let r = NavigationState.resolve(state: s, activeServerId: "srv")
        #expect(r?.instanceId == "inst-42")
        #expect(r?.sessionName == "ws-1")
    }

    @Test("resolve match nil sessionName → returns instanceId only")
    func resolveNoSession() {
        let s = NavigationState(serverId: "srv", instanceId: "inst-7",
                                sessionName: nil, savedAt: Date())
        let r = NavigationState.resolve(state: s, activeServerId: "srv")
        #expect(r?.instanceId == "inst-7")
        #expect(r?.sessionName == nil)
    }

    // MARK: - Cleanup (2 tests)

    @Test("clearSession clears navigation state")
    func clearSessionClearsNav() {
        let store = makeStore()
        store.clearNavigationState()
        store.saveNavigationState(NavigationState(
            serverId: "s", instanceId: "i", sessionName: nil, savedAt: Date()
        ))
        store.clearSession()
        #expect(store.loadNavigationState() == nil)
    }

    @Test("removeServer clears navigation state when serverId matches")
    func removeServerClearsNav() {
        let store = makeStore()
        store.clearNavigationState()
        let sid = "nav-rm-\(UUID().uuidString.prefix(8))"
        store.addServer(PairedServer(
            id: sid, host: "nav-\(sid).io", name: "t",
            role: nil, pairedAt: Date(), expiresAt: nil
        ), token: "t")
        store.saveNavigationState(NavigationState(
            serverId: sid, instanceId: "i", sessionName: nil, savedAt: Date()
        ))
        store.removeServer(id: sid)
        #expect(store.loadNavigationState() == nil)
    }
}
