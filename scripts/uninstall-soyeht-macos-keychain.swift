import Foundation
import Security

// Release-only uninstall helper. It targets the shipping
// `com.soyeht.household` namespace; Dev cleanup must use the app's
// profile-scoped reset/uninstaller paths instead.
let dryRun = CommandLine.arguments.contains("--dry-run")

private func itemCount(_ result: AnyObject?) -> Int {
    if result == nil { return 0 }
    if let items = result as? [[String: Any]] { return items.count }
    if result is [String: Any] { return 1 }
    return 0
}

private func genericPasswordCount(service: String, dataProtection: Bool) -> Int {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
    ]
    if dataProtection {
        query[kSecUseDataProtectionKeychain as String] = true
    }

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return status == errSecSuccess ? itemCount(result) : 0
}

private func statusIsOK(_ status: OSStatus, dataProtection _: Bool) -> Bool {
    if status == errSecSuccess || status == errSecItemNotFound {
        return true
    }
    return false
}

private func deleteLoginGenericPasswordsWithSecurityTool(service: String) -> Bool {
    let keychain = "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"
    var deleted = 0

    while deleted < 128 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", service, keychain]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            break
        }
        if process.terminationStatus == 0 {
            deleted += 1
        } else {
            break
        }
    }

    let remaining = genericPasswordCount(service: service, dataProtection: false)
    if remaining == 0 {
        print("[keychain] removed \(service) login items")
        return true
    }
    print("[warn] keychain login fallback left \(remaining) \(service) item(s)")
    return false
}

private func deleteGenericPasswords(service: String, dataProtection: Bool) -> Bool {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ]
    if dataProtection {
        query[kSecUseDataProtectionKeychain as String] = true
    }

    if dryRun {
        let count = genericPasswordCount(service: service, dataProtection: dataProtection)
        print("[dry-run] keychain \(service) \(dataProtection ? "data-protection" : "login"): \(count) item(s)")
        return true
    }

    let status = SecItemDelete(query as CFDictionary)
    if statusIsOK(status, dataProtection: dataProtection) {
        print("[keychain] removed \(service) \(dataProtection ? "data-protection" : "login") items")
        return true
    }
    if !dataProtection {
        return deleteLoginGenericPasswordsWithSecurityTool(service: service)
    }
    print("[warn] keychain delete failed for \(service) status=\(status)")
    return false
}

private func ownerKeyTags(dataProtection: Bool) -> [Data] {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    query[kSecUseDataProtectionKeychain as String] = dataProtection

    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
        return []
    }

    let rawItems: [[String: Any]]
    if let items = result as? [[String: Any]] {
        rawItems = items
    } else if let item = result as? [String: Any] {
        rawItems = [item]
    } else {
        rawItems = []
    }

    return rawItems.compactMap { item in
        guard let tag = item[kSecAttrApplicationTag as String] as? Data,
              let string = String(data: tag, encoding: .utf8),
              string.hasPrefix("com.soyeht.household.owner.") else {
            return nil
        }
        return tag
    }
}

private func deleteOwnerKeys(dataProtection: Bool) -> Bool {
    let tags = Array(Set(ownerKeyTags(dataProtection: dataProtection)))
    if dryRun {
        print("[dry-run] keychain owner signing keys \(dataProtection ? "data-protection" : "login"): \(tags.count) item(s)")
        return true
    }

    var ok = true
    for tag in tags {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag,
        ]
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        let status = SecItemDelete(query as CFDictionary)
        if !statusIsOK(status, dataProtection: dataProtection) {
            ok = false
            print("[warn] owner signing key delete failed status=\(status)")
        }
    }
    print("[keychain] removed \(tags.count) owner signing key(s) from \(dataProtection ? "data-protection" : "login") keychain")
    return ok
}

var ok = true
for service in ["com.soyeht.mobile", "com.soyeht.mac", "com.soyeht.household"] {
    ok = deleteGenericPasswords(service: service, dataProtection: true) && ok
    ok = deleteGenericPasswords(service: service, dataProtection: false) && ok
}
ok = deleteOwnerKeys(dataProtection: true) && ok
ok = deleteOwnerKeys(dataProtection: false) && ok

exit(ok ? 0 : 1)
