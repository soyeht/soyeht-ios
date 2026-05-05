import Foundation
import SoyehtCore

func makeIsolatedSessionStore() -> SoyehtCore.SessionStore {
    let id = UUID().uuidString
    let defaults = UserDefaults(suiteName: "com.soyeht.tests.\(id)")!
    defaults.removePersistentDomain(forName: "com.soyeht.tests.\(id)")
    return SoyehtCore.SessionStore(
        defaults: defaults,
        keychainService: "com.soyeht.mobile.tests.\(id)"
    )
}

func makeIsolatedSoyehtCoreSessionStore() -> SoyehtCore.SessionStore {
    makeIsolatedSessionStore()
}
