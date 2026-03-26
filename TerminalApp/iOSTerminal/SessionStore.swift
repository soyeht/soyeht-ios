import Foundation
import Security

final class SessionStore {
    static let shared = SessionStore()

    private let keychainService = "com.soyeht.mobile"
    private let keychainTokenKey = "session_token"
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let apiHost = "soyeht.apiHost"
        static let sessionExpiry = "soyeht.sessionExpiry"
        static let cachedInstances = "soyeht.cachedInstances"
    }

    // MARK: - Session (Keychain + UserDefaults)

    func saveSession(token: String, host: String, expiresAt: String) {
        saveToKeychain(key: keychainTokenKey, value: token)
        defaults.set(host, forKey: Keys.apiHost)
        defaults.set(expiresAt, forKey: Keys.sessionExpiry)
    }

    func loadSession() -> (token: String, host: String)? {
        guard let token = loadFromKeychain(key: keychainTokenKey),
              let host = defaults.string(forKey: Keys.apiHost) else {
            return nil
        }
        return (token, host)
    }

    func clearSession() {
        deleteFromKeychain(key: keychainTokenKey)
        defaults.removeObject(forKey: Keys.apiHost)
        defaults.removeObject(forKey: Keys.sessionExpiry)
        defaults.removeObject(forKey: Keys.cachedInstances)
    }

    var apiHost: String? {
        defaults.string(forKey: Keys.apiHost)
    }

    var sessionToken: String? {
        loadFromKeychain(key: keychainTokenKey)
    }

    // MARK: - Cached Instances

    func saveInstances(_ instances: [SoyehtInstance]) {
        if let data = try? JSONEncoder().encode(instances) {
            defaults.set(data, forKey: Keys.cachedInstances)
        }
    }

    func loadInstances() -> [SoyehtInstance] {
        guard let data = defaults.data(forKey: Keys.cachedInstances),
              let instances = try? JSONDecoder().decode([SoyehtInstance].self, from: data) else {
            return []
        }
        return instances
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
