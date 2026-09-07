import Foundation
import Security
import os
import LocalAuthentication

private let keychainLog = Logger(subsystem: "com.soyeht.core", category: "keychain")

private func keychainErrorLog(_ message: String) {
    keychainLog.error("\(message, privacy: .public)")
}

/// Injectable at the Security API boundary so failure tests never access a
/// person's Keychain. Implementations must serialize their own mutable state.
protocol KeychainOperations: Sendable {
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemKeychainOperations: KeychainOperations {
    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainHelper: Sendable {
    public let service: String
    public let accessibility: String
    private let operations: any KeychainOperations

    public init(service: String, accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock) {
        self.service = service
        self.accessibility = accessibility as String
        self.operations = SystemKeychainOperations()
    }

    init(service: String, accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock,
         operations: any KeychainOperations) {
        self.service = service
        self.accessibility = accessibility as String
        self.operations = operations
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

    private func upsert(_ query: [String: Any], data: Data) -> OSStatus {
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        // Never delete as part of replacement. A failed update preserves the
        // previous value, including when authentication is unavailable.
        let status = operations.update(query, attributes: attrs)
        guard status == errSecItemNotFound else { return status }
        var item = query
        item.merge(attrs) { _, new in new }
        let added = operations.add(item)
        guard added == errSecDuplicateItem else { return added }
        // Another writer inserted between update and add. Retry the update
        // once; do not delete that writer's value or spin on contention.
        return operations.update(query, attributes: attrs)
    }

    @discardableResult
    /// Replaces the value; this is not compare-and-swap. Concurrent successful
    /// writers may replace one another. Failure logs omit account identifiers
    /// because this generic API also stores credentials keyed by private IDs.
    public func save(_ data: Data, account: String) -> Bool {
        let status = upsert(baseQuery(account: account), data: data)
        if status == errSecSuccess { return true }

        // Fallback: App-Store / sandboxed builds without a
        // `keychain-access-groups` entitlement return
        // `errSecMissingEntitlement` for the data-protection keychain. In
        // that case drop back to the legacy/login keychain so the item still
        // persists; callers see the same API surface.
        #if os(macOS)
        if status == errSecMissingEntitlement {
            let fallback = upsert(legacyBaseQuery(account: account), data: data)
            if fallback == errSecSuccess { return true }
            keychainErrorLog("save failed backend=legacy status=\(fallback)")
            return false
        }
        #endif

        keychainErrorLog("save failed backend=primary status=\(status)")
        return false
    }

    @discardableResult
    public func saveString(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, account: account)
    }

    public func load(account: String) -> Data? {
        do { return try loadWithoutInteraction(account: account) }
        catch {
            // Compatibility for optional callers. Authority/session code must
            // use the throwing API; this log is not evidence of absence.
            let failure = error as NSError
            keychainErrorLog("load unavailable domain=\(failure.domain) code=\(failure.code)")
            return nil
        }
    }

    /// Absence and unavailable authentication must remain distinct for authority
    /// decisions. Never falls back to another store after an authentication error.
    public func loadWithoutInteraction(account: String) throws -> Data? {
        try loadDiagnosed(account: account, allowInteraction: false)
    }

    public func loadDiagnosed(account: String, allowInteraction: Bool) throws -> Data? {
        func read(_ base: [String: Any]) throws -> Data? {
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = !allowInteraction
            query[kSecUseAuthenticationContext as String] = context
            let (status, result) = operations.copyMatching(query)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                throw OwnerIdentityKeyError.securityFailure(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            guard let data = result as? Data else { throw HouseholdSessionError.decodingFailed }
            return data
        }
        #if os(macOS)
        var primaryFailure: Error?
        #endif
        do {
            if let data = try read(baseQuery(account: account)) { return data }
        } catch {
            #if os(macOS)
            guard error as? OwnerIdentityKeyError == .securityFailure(
                domain: NSOSStatusErrorDomain, code: Int(errSecMissingEntitlement)
            ) else { throw error }
            primaryFailure = error
            #else
            throw error
            #endif
        }
        #if os(macOS)
        if let data = try read(legacyBaseQuery(account: account)) { return data }
        // An unreadable primary store plus an absent legacy item does not
        // establish absence. Preserve the error for authority decisions.
        if let primaryFailure { throw primaryFailure }
        return nil
        #else
        return nil
        #endif
    }

    public func loadString(account: String) -> String? {
        guard let data = load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func deleteStatus(account: String) -> OSStatus {
        // DP-only delete. Legacy/login-keychain items created by older
        // builds under a different code signature are left orphaned (the
        // current binary can't touch them without the ACL prompt). They
        // do no harm — next save into the DP keychain owns the entry.
        operations.delete(baseQuery(account: account))
    }

    public func delete(account: String) {
        deleteStatus(account: account)
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
        let (status, result) = operations.copyMatching(query)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func deleteAll() {
        for account in allAccounts() { delete(account: account) }
    }
}
