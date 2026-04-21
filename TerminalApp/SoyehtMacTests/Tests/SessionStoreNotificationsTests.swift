import XCTest
import Foundation
import SoyehtCore

/// Regression coverage for `SoyehtCore.SessionStore.setActiveServer(id:)`
/// publishing `ClawStoreNotifications.activeServerChanged`. The macOS
/// `InstalledClawsProvider` subscribes to this notification so the pane
/// picker re-fetches from the new server's context; if the notification
/// stops firing the picker silently serves stale data from the previous
/// server (MPCI-012).
///
/// (The iOS app has its own `SessionStore` type under `TerminalApp/Soyeht/`
/// that predates the SoyehtCore unification and does NOT consume this
/// notification — the pane picker + provider are macOS-only.)
final class SessionStoreNotificationsTests: XCTestCase {

    func test_setActiveServer_postsActiveServerChangedNotification() async {
        let store = makeIsolatedSessionStore()
        let serverA = makePairedServer(id: "ssn-a", host: "ssn-a.test.io", name: "a")
        let serverB = makePairedServer(id: "ssn-b", host: "ssn-b.test.io", name: "b")
        store.addServer(serverA, token: "ta")
        store.addServer(serverB, token: "tb")

        let received = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.activeServerChanged,
            object: nil,
            queue: nil
        ) { _ in received.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setActiveServer(id: serverB.id)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThanOrEqual(received.count, 1,
                                    "setActiveServer must post ClawStoreNotifications.activeServerChanged")
    }

    func test_activeServerChangedNotification_firesAfterActiveServerIdIsPersisted() async {
        // Observers (InstalledClawsProvider) read `currentContext()` / `activeServerId`
        // inside their callback. The notification must arrive AFTER the write,
        // otherwise the observer reads the stale value and re-fetches from the
        // wrong server.
        let store = makeIsolatedSessionStore()
        let serverA = makePairedServer(id: "ssn-ord-a", host: "ssn-ord-a.test.io", name: "a")
        let serverB = makePairedServer(id: "ssn-ord-b", host: "ssn-ord-b.test.io", name: "b")
        store.addServer(serverA, token: "ta")
        store.addServer(serverB, token: "tb")
        store.setActiveServer(id: serverA.id)

        let seenActiveId = ObservedValue<String>()
        let observer = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.activeServerChanged,
            object: nil,
            queue: nil
        ) { _ in seenActiveId.set(store.activeServerId) }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setActiveServer(id: serverB.id)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(seenActiveId.value, serverB.id,
                       "Observer must read the NEW activeServerId inside the notification callback — " +
                       "posting before persistence would leak the old value to refreshers that consult the store")
    }

    // MARK: - Helpers

    private func makeIsolatedSessionStore() -> SessionStore {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.soyeht.tests.sessionStore.\(id)")!
        defaults.removePersistentDomain(forName: "com.soyeht.tests.sessionStore.\(id)")
        return SessionStore(
            defaults: defaults,
            keychainService: "com.soyeht.mobile.tests.sessionStore.\(id)"
        )
    }

    private func makePairedServer(id: String, host: String, name: String) -> PairedServer {
        PairedServer(id: id, host: host, name: name, role: "admin", pairedAt: Date(), expiresAt: nil)
    }
}

// MARK: - Test Primitives

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
}

private final class ObservedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ newValue: T?) { lock.lock(); _value = newValue; lock.unlock() }
}
