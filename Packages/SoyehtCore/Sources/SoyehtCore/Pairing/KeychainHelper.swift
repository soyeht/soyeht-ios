import Foundation
import Security
import os
#if canImport(LocalAuthentication)
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
        // Prefer the data-protection keychain; fall back to the legacy
        // keychain so items created by older builds (pre-migration) are
        // still readable. `UIFail` on the legacy query prevents the ACL
        // password prompt from appearing for rebuilds with a different
        // code signature — if the item isn't accessible, we just return nil.
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        #if os(macOS)
        var legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        Self.attachNoUIContext(to: &legacy)
        if SecItemCopyMatching(legacy as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        #endif
        return nil
    }

    #if os(macOS)
    /// Attaches an `LAContext` with `interactionNotAllowed = true` to a
    /// legacy-keychain query so a login-keychain ACL mismatch (e.g. after
    /// rebuilding the app with a different ad-hoc code signature) returns
    /// `errSecInteractionNotAllowed` instead of popping the "allow access
    /// to com.soyeht.mac" password prompt. The caller interprets nil as
    /// "no item for this identity" and moves on to re-pair.
    private static func attachNoUIContext(to query: inout [String: Any]) {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = ctx
    }
    #endif

    public func loadString(account: String) -> String? {
        guard let data = load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        #if os(macOS)
        // Also prune a legacy/login-keychain twin, if any. Deletes don't
        // trigger the ACL password prompt on macOS.
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(legacy as CFDictionary)
        #endif
    }

    public func allAccounts() -> [String] {
        var items: [[String: Any]] = []
        var result: AnyObject?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let dp = result as? [[String: Any]] {
            items.append(contentsOf: dp)
        }
        #if os(macOS)
        // Also enumerate the legacy keychain so older items stay visible
        // until they migrate to the data-protection keychain on next save.
        var legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        Self.attachNoUIContext(to: &legacy)
        if SecItemCopyMatching(legacy as CFDictionary, &result) == errSecSuccess,
           let lg = result as? [[String: Any]] {
            items.append(contentsOf: lg)
        }
        #endif
        var seen: Set<String> = []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { seen.insert($0).inserted }
    }

    public func deleteAll() {
        for account in allAccounts() { delete(account: account) }
    }
}
