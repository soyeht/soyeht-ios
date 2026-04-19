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
        // Use the Data Protection Keychain on macOS 10.15+: items are scoped
        // to the bundle identifier instead of per-binary ACL, so rebuilding
        // the app with a different ad-hoc code signature (Debug "Sign to
        // Run Locally") no longer surfaces the login-keychain "allow access
        // to com.soyeht.mac" password prompt on every launch. iOS has no
        // legacy keychain at all — same API, same behavior.
        //
        // If `SecItemAdd` ever returns `errSecMissingEntitlement` on a
        // sandboxed/App-Store build, `save(_:account:)` falls back to the
        // legacy keychain (see below).
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    @discardableResult
    public func save(_ data: Data, account: String) -> Bool {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return true }

        // Fallback: App-Store / sandboxed builds without a
        // `keychain-access-groups` entitlement return
        // `errSecMissingEntitlement` for the data-protection keychain. In
        // that case drop back to the legacy/login keychain so the item still
        // persists; callers see the same API surface.
        #if os(macOS)
        if status == errSecMissingEntitlement {
            var legacy: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(legacy as CFDictionary)
            legacy[kSecValueData as String] = data
            legacy[kSecAttrAccessible as String] = accessibility
            let fallback = SecItemAdd(legacy as CFDictionary, nil)
            if fallback == errSecSuccess { return true }
            keychainErrorLog("save failed (legacy fallback) account=\(account) status=\(fallback)")
            return false
        }
        #endif

        keychainErrorLog("save failed account=\(account) status=\(status)")
        return false
    }

    @discardableResult
    public func saveString(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, account: account)
    }

    public func load(account: String) -> Data? {
        // Read the data-protection keychain ONLY. Falling back to the
        // legacy/login keychain on miss re-introduces the ACL password
        // prompt whenever an older build had written items there under a
        // different ad-hoc code signature — `LAContext.interactionNotAllowed`
        // only suppresses biometric/passcode prompts, not the login-keychain
        // trusted-apps ACL prompt. Treat "not in DP" as "not paired";
        // callers reenter the pair flow and write the new item into DP.
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
        // DP-only delete. Legacy/login-keychain items created by older
        // builds under a different code signature are left orphaned (the
        // current binary can't touch them without the ACL prompt). They
        // do no harm — next save into the DP keychain owns the entry.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    public func allAccounts() -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func deleteAll() {
        for account in allAccounts() { delete(account: account) }
    }
}
