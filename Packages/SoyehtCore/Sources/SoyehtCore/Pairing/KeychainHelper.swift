import Foundation
import Security
import os
#if os(macOS)
import LocalAuthentication
#endif

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

    #if os(macOS)
    private func legacyBaseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif

    private func update(_ query: [String: Any], data: Data, account: String, label: String) -> Bool {
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        keychainErrorLog("update failed (\(label)) account=\(account) status=\(status)")
        return false
    }

    @discardableResult
    public func save(_ data: Data, account: String) -> Bool {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem {
            return update(baseQuery(account: account), data: data, account: account, label: "data-protection duplicate")
        }

        // Fallback: App-Store / sandboxed builds without a
        // `keychain-access-groups` entitlement return
        // `errSecMissingEntitlement` for the data-protection keychain. In
        // that case drop back to the legacy/login keychain so the item still
        // persists; callers see the same API surface.
        #if os(macOS)
        if status == errSecMissingEntitlement {
            var legacy = legacyBaseQuery(account: account)
            SecItemDelete(legacy as CFDictionary)
            legacy[kSecValueData as String] = data
            legacy[kSecAttrAccessible as String] = accessibility
            let fallback = SecItemAdd(legacy as CFDictionary, nil)
            if fallback == errSecSuccess { return true }
            if fallback == errSecDuplicateItem {
                return update(
                    legacyBaseQuery(account: account),
                    data: data,
                    account: account,
                    label: "legacy duplicate"
                )
            }
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
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #if os(macOS)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        #endif
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }

        #if os(macOS)
        // Development builds signed to run locally can lack the entitlement
        // needed for the data-protection keychain. In that case `save` falls
        // back to the legacy keychain; read it without allowing UI prompts.
        var legacy = legacyBaseQuery(account: account)
        legacy[kSecReturnData as String] = true
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        legacy[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let noPromptContext = LAContext()
        noPromptContext.interactionNotAllowed = true
        legacy[kSecUseAuthenticationContext as String] = noPromptContext
        result = nil
        if SecItemCopyMatching(legacy as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        #endif

        return nil
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
