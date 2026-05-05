import Foundation
import SoyehtCore
@testable import Soyeht

func makeIsolatedSessionStore() -> Soyeht.SessionStore {
    let id = UUID().uuidString
    let defaults = UserDefaults(suiteName: "com.soyeht.tests.\(id)")!
    defaults.removePersistentDomain(forName: "com.soyeht.tests.\(id)")
    return Soyeht.SessionStore(
        defaults: defaults,
        keychainService: "com.soyeht.mobile.tests.\(id)"
    )
}

func makeIsolatedSoyehtCoreSessionStore() -> SoyehtCore.SessionStore {
    let id = UUID().uuidString
    let defaults = UserDefaults(suiteName: "com.soyeht.tests.vm.\(id)")!
    defaults.removePersistentDomain(forName: "com.soyeht.tests.vm.\(id)")
    return SoyehtCore.SessionStore(
        defaults: defaults,
        keychainService: "com.soyeht.mobile.tests.vm.\(id)"
    )
}
