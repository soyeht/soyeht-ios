#if DEBUG
import Foundation
import Security
import SoyehtCore

/// Puts a Dev Mac back to the state a brand new machine is in, so onboarding can
/// be tested from zero without hand-running a page of shell commands.
///
/// Runs only when `DevLocalStateResetGate` says every Dev signal agrees, and
/// only ever touches this build's namespaces: the `SoyehtDev` support
/// directory, `~/.theyos-dev`, the `com.soyeht.engine.dev` LaunchAgent, the
/// `com.soyeht.mac.dev` preference domain and keychain services. The shipping
/// install and its engine are never stopped or read.
///
/// Deliberately NOT done here: `tccutil reset` (a QA reset must not make the
/// owner re-grant Accessibility and Screen Recording) and MCP config rewrites
/// (those are shared with other agents on this machine).
enum DevLocalStateReset {
    /// Returns true when the reset ran (or was refused after being asked for),
    /// which means the caller must not continue launching the app.
    @MainActor
    static func startIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let profile = SoyehtInstallProfile.current

        switch DevLocalStateResetGate.decision(
            environment: environment,
            arguments: arguments,
            bundleIdentifier: bundleIdentifier,
            profile: profile
        ) {
        case .notRequested:
            return false
        case .refused(let reason):
            NSLog("[DevLocalStateReset] refused reason=%@", reason)
            exit(2)
        case .run:
            Task { @MainActor in
                await run(profile: profile, bundleIdentifier: bundleIdentifier)
            }
            return true
        }
    }

    @MainActor
    private static func run(profile: SoyehtInstallProfile, bundleIdentifier: String?) async {
        NSLog("[DevLocalStateReset] stage=begin profile=%@", profile.kind.rawValue)

        // 1. Stop the engine the Apple way first, then the launchctl fallback
        //    the Welcome flow already uses for legacy registrations.
        try? SMAppServiceInstaller.unregister()
        await ExistingSoyehtStopper.stopKnownServices()
        try? await Task.sleep(for: .seconds(1))

        // 2. Delete this build's files. The uninstall plan lists shipping paths
        //    too (it is shared with the full uninstaller), so every item is
        //    filtered down to Dev-only namespaces before anything is removed.
        let items = TheyOSUninstallPlan.removalItems(
            profile: profile,
            includeApplicationBundles: false,
            includeEngine: true,
            includeUserData: true,
            includeCachesAndLogs: true,
            includeMCPArtifacts: false,
            includePreferences: false
        )
        let removed = removeDevScopedItems(items)
        NSLog("[DevLocalStateReset] stage=files removed=%d of=%d", removed, items.count)

        // 3. The support directory is gone by now; this also covers a partial
        //    plan (older engine layouts kept databases beside it).
        await ExistingSoyehtStateResetter.resetLocalEngineState()

        // 4. Forget every server and every paired iPhone.
        for id in SessionStore.shared.pairedServers.map(\.id) {
            SessionStore.shared.removeServer(id: id)
        }
        SessionStore.shared.clearSession()
        PairingStore.shared.revokeAll()

        // 5. Household session, its Secure Enclave keys, and the CRL.
        await clearHouseholdState()

        // 6. Keychain services and the preference domain, Dev namespaces only.
        clearDevKeychainServices(profile: profile)
        let domain = bundleIdentifier ?? DevLocalStateResetGate.requiredBundleIdentifier
        UserDefaults.standard.removePersistentDomain(forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)

        NSLog("[DevLocalStateReset] stage=done domain=%@", domain)
        exit(0)
    }

    /// A path is Dev-scoped when it names this build somewhere in it. Anything
    /// else in the plan belongs to the shipping install and is left alone.
    static func isDevScoped(path: String) -> Bool {
        let markers = [
            "/SoyehtDev",
            "SoyehtDev/",
            "/.theyos-dev",
            "/theyos-dev",
            "soyehtdev-",
            "com.soyeht.mac.dev",
            "com.soyeht.engine.dev",
            "com.soyeht.household.dev",
            "com.soyeht.mobile.dev",
            "soyeht-dev-mcp",
            "Soyeht Dev",
        ]
        return markers.contains { path.contains($0) }
    }

    private static func removeDevScopedItems(_ items: [TheyOSRemovalItem]) -> Int {
        let fileManager = FileManager.default
        var removed = 0
        for item in items where isDevScoped(path: item.url.path) {
            if (try? fileManager.removeItem(at: item.url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    private static func clearHouseholdState() async {
        let householdStore = HouseholdSessionStore()
        if let household = try? householdStore.load() {
            deleteSecureEnclaveKey(reference: household.ownerKeyReference)
            if let deviceKeyReference = household.deviceKeyReference {
                deleteSecureEnclaveKey(reference: deviceKeyReference)
            }
        }
        householdStore.clear()
        if let crl = try? CRLStore() {
            await crl.clear()
        }
    }

    private static func deleteSecureEnclaveKey(reference: String) {
        guard let tag = reference.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func clearDevKeychainServices(profile: SoyehtInstallProfile) {
        for service in [
            profile.mobileKeychainService,
            profile.keychainService,
            profile.keychainService + ".agent-launch-ownership",
            profile.householdKeychainService,
        ] where isDevScoped(path: service) {
            deleteGenericPasswordService(service, dataProtection: true)
            deleteGenericPasswordService(service, dataProtection: false)
        }
    }

    private static func deleteGenericPasswordService(_ service: String, dataProtection: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        SecItemDelete(query as CFDictionary)
    }
}
#endif
