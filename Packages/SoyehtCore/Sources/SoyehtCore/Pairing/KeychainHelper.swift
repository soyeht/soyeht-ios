import Foundation
import Security
import os

private let keychainLog = Logger(subsystem: "com.soyeht.core", category: "keychain")

private func keychainErrorLog(_ message: String) {
    keychainLog.error("\(message, privacy: .public)")
}

public struct KeychainHelper: Sendable {
    public let service: String
    public let accessibility: String

    public init(service: String, accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock) {
        self.service = service
        self.accessibility = accessibility as String
    }

    private func baseQuery(account: String) -> [String: Any] {
        // NOTE: `kSecUseDataProtectionKeychain` was tried here but silently
        // fails SecItemAdd on non-sandboxed macOS apps without the
        // `keychain-access-groups` entitlement. Stick with the legacy/login
        // keychain — non-sandboxed apps can write to their own items without
        // prompts, and iOS only has one keychain anyway.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    public func save(_ data: Data, account: String) -> Bool {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            keychainErrorLog("save failed account=\(account) status=\(status)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    public func saveString(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, account: account)
    }

    public func load(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    public func loadString(account: String) -> String? {
        guard let data = load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    public func allAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func deleteAll() {
        for account in allAccounts() { delete(account: account) }
    }
}
