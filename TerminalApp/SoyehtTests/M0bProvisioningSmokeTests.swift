import Foundation
import NetworkExtension
import Security
import SoyehtCore
import XCTest
#if canImport(UIKit)
import UIKit
#endif

@testable import Soyeht

/// M0b provisioning smoke test (soyeht-plano.md M0b). Drives the REAL
/// Network Extension lifecycle on a physical device: writes a value into the
/// shared Keychain Access Group, starts `SoyehtClawShareTunnelProvider` with
/// a private sentinel that routes it into `M0bSmokeCheck` (Dev-only, never
/// reachable in Release), and reads back the result the extension wrote into
/// the shared App Group. Requires a physical device — Network Extension
/// provisioning is exactly what's under test, so a simulator run proves
/// nothing here.
///
/// Constants below intentionally duplicate `M0bSmokeCheck` in the
/// `SoyehtClawShareTunnelProvider` target rather than share a type: the two
/// targets are on opposite sides of the boundary being tested, and a shared
/// dependency would hide a real wiring mismatch instead of catching it.
final class M0bProvisioningSmokeTests: XCTestCase {
    private let sentinelKey = "com.soyeht.mobile.clawshare.m0bSmokeSentinel"
    private let sentinelValue = "m0b-2026-08-08"
    private let keychainService = "com.soyeht.mobile.clawshare.m0bSmoke"
    private let keychainAccount = "smokeValue"
    private let appGroupSuiteName = "group.com.soyeht.mobile.clawshare.dev"
    private let resultDefaultsKey = "m0bSmokeResult"
    private let testKeychainValue = "m0b-keychain-probe"

    // M4-premise canary (soyeht-plano.md M4): which kSecAttrAccessible*
    // class actually survives a genuinely, physically locked device.
    private let canarySentinelKey = "com.soyeht.mobile.clawshare.m0bKeychainCanarySentinel"
    private let canarySentinelValue = "m0b-canary-2026-08-09"
    private let canaryWhenUnlockedAccount = "canaryWhenUnlockedThisDeviceOnly"
    private let canaryAfterFirstUnlockAccount = "canaryAfterFirstUnlockThisDeviceOnly"
    private let canaryWhenPasscodeSetAccount = "canaryWhenPasscodeSetThisDeviceOnly"
    private let canaryResultDefaultsKey = "m0bKeychainCanaryResult"
    private let canaryProtectedFileName = "m0b-keybag-probe.dat"

    /// Read-only: lists whatever VPN configurations already exist for this
    /// app so we know whether a prior-approved `SoyehtClawShareTunnelProvider`
    /// configuration can be reused (skipping the interactive "Add VPN
    /// Configurations" passcode prompt) instead of always creating a fresh
    /// one. Never calls saveToPreferences/startVPNTunnel, so it cannot
    /// trigger any system dialog.
    func testDiagnoseExistingTunnelProviderManagers() async throws {
        #if targetEnvironment(simulator)
        // Unlike its sibling tests, this one doesn't call save/start, so it
        // looked simulator-safe — but `loadAllFromPreferences()` itself goes
        // over NEVPNManager's real IPC to the system's Network Extension
        // daemon, which the simulator can't service: `NEVPNErrorDomain
        // Code=5 "IPC failed"` on every CI run, confirmed identical on the
        // commit before this guard was added. Matches the class-level doc:
        // this whole suite requires a physical device.
        throw XCTSkip("M0b proves physical-device provisioning; simulator run cannot validate it.")
        #else
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        print("M0B_DIAG: found \(managers.count) existing NETunnelProviderManager(s)")
        for (index, manager) in managers.enumerated() {
            let bundleID = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier ?? "<none>"
            print(
                "M0B_DIAG[\(index)]: bundleID=\(bundleID) "
                + "description=\(manager.localizedDescription ?? "<none>") "
                + "enabled=\(manager.isEnabled) "
                + "status=\(manager.connection.status.rawValue)"
            )
        }
        #endif
    }

    /// Read/write-only diagnostic: proves whether THIS process (the test
    /// host) can round-trip a value through the shared App Group at all,
    /// independent of the extension. Isolates "the extension never wrote"
    /// from "this process can't see writes" (a `cfprefsd` container-caching
    /// issue would show up here without touching the VPN config).
    func testAppGroupRoundTrip() throws {
        let probeKey = "m0bAppGroupRoundTripProbe"
        let probeValue = "probe-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else {
            XCTFail("UserDefaults(suiteName:) returned nil for \(appGroupSuiteName)")
            return
        }
        defaults.set(probeValue, forKey: probeKey)
        defaults.synchronize()
        // Fresh instance, deliberately, to bypass any object-level cache.
        let readBack = UserDefaults(suiteName: appGroupSuiteName)?.string(forKey: probeKey)
        print(
            "APP_GROUP_ROUNDTRIP_JSONL: "
            + "{\"wrote\":\"\(probeValue)\",\"read\":\"\(readBack ?? "nil")\","
            + "\"match\":\(readBack == probeValue)}"
        )
        XCTAssertEqual(readBack, probeValue, "App Group round-trip failed in this process")
    }

    func testExtensionLoadsReadsKeychainAndCallsFFI() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("M0b proves physical-device provisioning; simulator run cannot validate it.")
        #else
        UserDefaults(suiteName: appGroupSuiteName)?.removeObject(forKey: resultDefaultsKey)
        try writeKeychainProbeValue()

        let manager = try await startSmokeTunnel(options: [
            sentinelKey: sentinelValue as NSString,
        ])

        let result = try await pollForResult(defaultsKey: resultDefaultsKey)
        // Diagnostic: if the extension's own crash-loop earlier in this
        // session tripped NetworkExtension's built-in relaunch backoff, the
        // status here tells us the system never attempted this launch at
        // all, instead of guessing from an empty result alone.
        print("M0B_STATUS_AFTER_POLL: \(manager.connection.status.rawValue)")
        let failure = result["failure"] as? String
        XCTAssertNil(failure, "M0b smoke check reported failure: \(failure ?? "")")
        let steps = result["steps"] as? [String] ?? []
        XCTAssertTrue(steps.contains { $0.hasPrefix("keychain_read_ok:") }, "steps: \(steps)")
        XCTAssertTrue(steps.contains("ffi_call_ok"), "steps: \(steps)")
        #endif
    }

    private func writeKeychainProbeValue() throws {
        let accessGroup = try MeshTunnelKeychainAccessGroup.resolve(from: .main)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: accessGroup.value,
        ]
        // Deterministic every run, matching addCanaryItem: SecItemUpdate
        // cannot change kSecAttrAccessible on an existing item, so a leftover
        // item from an older run (created under the old, unspecified default
        // of WhenUnlocked) would silently keep testing the wrong class
        // forever. Delete first, always add fresh with the class M4 actually
        // needs for background reconnect.
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(testKeychainValue.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        try XCTUnwrap(addStatus == errSecSuccess ? () : nil, "SecItemAdd failed: \(addStatus)")
    }

    /// Requires `done == true`, not just a non-nil dictionary: the extension
    /// writes a `done: false` diagnostic checkpoint before its real work, to
    /// the same key the real result lands on. A poll that stopped on any
    /// non-nil value could return that checkpoint instead of the answer —
    /// this waits for the write the extension actually intends as final.
    private func pollForResult(
        defaultsKey: String,
        timeout: TimeInterval = 20,
        interval: TimeInterval = 0.5
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = UserDefaults(suiteName: appGroupSuiteName)?
                .dictionary(forKey: defaultsKey),
               result["done"] as? Bool == true
            {
                return result
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("M0b result never appeared in the shared App Group (\(defaultsKey)) within \(timeout)s")
        return [:]
    }

    /// Reuses an already-approved `SoyehtClawShareTunnelProvider`
    /// configuration when one exists (deleting and recreating one, tried
    /// once already, didn't change any outcome — no reason to keep
    /// spending interactive approvals on it), saves it, and starts the
    /// tunnel with the given options.
    private func startSmokeTunnel(options: [String: NSObject]) async throws -> NETunnelProviderManager {
        let hostBundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let providerBundleID = "\(hostBundleID).SoyehtClawShareTunnelProvider"

        let existingManagers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = existingManagers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
        } ?? NETunnelProviderManager()

        let protocolConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = providerBundleID
        protocolConfiguration.serverAddress = "m0b-smoke"
        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = "M0b Smoke Test"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        try manager.connection.startVPNTunnel(options: options)
        print("M0B_STATUS_AFTER_START: \(manager.connection.status.rawValue)")
        return manager
    }

    /// M4-premise canary: proves which `kSecAttrAccessible*` class actually
    /// survives a genuinely, physically locked device, from inside the
    /// extension. Requires a REAL lock via the device's side/top button.
    /// `mobile: lock` (Appium/WDA) was tried first and measured as
    /// insufficient — the same canaries stayed readable under it — but that
    /// measurement was itself taken in an Xcode/XCTest-attached context, so
    /// it does not by itself prove `mobile: lock` is the cause; see the
    /// method-level note below on the attached-context finding. This test
    /// prints an instruction and pauses; a human must lock the device
    /// during that window for the assertions below to mean anything.
    func testKeychainAccessibilityCanaryUnderLock() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a real, physically locked device.")
        #else
        UserDefaults(suiteName: appGroupSuiteName)?.removeObject(forKey: canaryResultDefaultsKey)
        try addCanaryItem(account: canaryWhenUnlockedAccount, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        try addCanaryItem(
            account: canaryAfterFirstUnlockAccount,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        try addCanaryItem(
            account: canaryWhenPasscodeSetAccount,
            accessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        )
        // Verify each write actually landed with the class we asked for,
        // while still unlocked — a wrong-class write would otherwise look
        // identical to a keybag that never locked.
        try assertCanaryAccessible(account: canaryWhenUnlockedAccount, expected: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        try assertCanaryAccessible(
            account: canaryAfterFirstUnlockAccount,
            expected: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        try assertCanaryAccessible(
            account: canaryWhenPasscodeSetAccount,
            expected: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        )

        // Direct, non-Keychain keybag observable: created and CLOSED here,
        // while unlocked, then read from the extension's own process after
        // lock. Complete file protection uses the same keybag class family
        // as WhenUnlocked, with zero Keychain/SecItem code in the path.
        try writeProtectedProbeFile()

        print("M0B_CANARY_LOCK_NOW: lock this device with the physical button and leave it locked")
        // 15s wasn't enough on the first attempt; 45s measured as fully
        // respected (test duration matched the sleep exactly) still showed
        // WhenUnlocked as readable. That already rules out timing — do not
        // increase this further, it would just produce the same answer
        // slower.
        try await Task.sleep(nanoseconds: 45 * 1_000_000_000)

        // Captured on the main thread, immediately before starting the
        // tunnel: Apple's own definition of "data protection active" for
        // this process. If this is true, the keybag has not locked in this
        // context at all, and interpreting the Keychain reads below would
        // be reading noise — fail fast instead of guessing.
        let protectedDataAvailable = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        print("M0B_HOST_PROTECTED_DATA_AVAILABLE: \(protectedDataAvailable)")

        _ = try await startSmokeTunnel(options: [
            canarySentinelKey: canarySentinelValue as NSString,
        ])

        let result = try await pollForResult(defaultsKey: canaryResultDefaultsKey)
        let whenUnlockedStatus = result["whenUnlockedStatus"] as? Int
        let afterFirstUnlockStatus = result["afterFirstUnlockStatus"] as? Int
        let whenPasscodeSetStatus = result["whenPasscodeSetStatus"] as? Int
        let protectedFileReadable = result["protectedFileReadable"] as? Bool
        print(
            "M0B_CANARY_JSONL: "
            + "{\"when_unlocked_status\":\(whenUnlockedStatus.map(String.init) ?? "null"),"
            + "\"after_first_unlock_status\":\(afterFirstUnlockStatus.map(String.init) ?? "null"),"
            + "\"when_passcode_set_status\":\(whenPasscodeSetStatus.map(String.init) ?? "null"),"
            + "\"protected_file_readable\":\(protectedFileReadable.map { "\($0)" } ?? "null"),"
            + "\"host_protected_data_available\":\(protectedDataAvailable)}"
        )

        guard !protectedDataAvailable, protectedFileReadable == false else {
            XCTFail(
                "Instrument invalid, not a Keychain finding: "
                + "host isProtectedDataAvailable=\(protectedDataAvailable), "
                + "extension protectedFileReadable=\(protectedFileReadable.map { "\($0)" } ?? "unknown") "
                + "— no protected-data state was observable in this measured, Xcode/XCTest-attached-via-USB "
                + "context, despite a real physical lock. Cause not isolated among debugger, XCTest, USB, or "
                + "some combination — do not assume which one. The next test needs to remove the whole "
                + "attached context, not swap one guessed component for another."
            )
            return
        }
        XCTAssertEqual(
            whenUnlockedStatus,
            Int(errSecInteractionNotAllowed),
            "WhenUnlockedThisDeviceOnly item was readable while locked, but the keybag DID lock per the file probe — capture attributes and file feedback"
        )
        XCTAssertEqual(
            afterFirstUnlockStatus,
            Int(errSecSuccess),
            "AfterFirstUnlockThisDeviceOnly item was NOT readable while locked — the M4 premise is false"
        )
        #endif
    }

    private func assertCanaryAccessible(account: String, expected: CFString) throws {
        let accessGroup = try MeshTunnelKeychainAccessGroup.resolve(from: .main)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup.value,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try XCTUnwrap(status == errSecSuccess ? () : nil, "Could not read back attributes for \(account): \(status)")
        let attributes = result as? [String: Any]
        let actual = attributes?[kSecAttrAccessible as String] as? String
        XCTAssertEqual(actual, expected as String, "\(account) has wrong kSecAttrAccessible after write")
    }

    private func writeProtectedProbeFile() throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupSuiteName
        ) else {
            throw XCTSkip("Could not resolve shared App Group container URL")
        }
        let fileURL = containerURL.appendingPathComponent(canaryProtectedFileName)
        try? FileManager.default.removeItem(at: fileURL)
        try Data("keybag-probe".utf8).write(to: fileURL, options: .completeFileProtection)
    }

    private func addCanaryItem(account: String, accessible: CFString) throws {
        let accessGroup = try MeshTunnelKeychainAccessGroup.resolve(from: .main)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup.value,
        ]
        // Deterministic every run: delete any prior item first rather than
        // updating one, since SecItemUpdate cannot change kSecAttrAccessible
        // on an existing item — a leftover item from an older run would
        // silently keep testing the wrong class.
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data("canary".utf8)
        addQuery[kSecAttrAccessible as String] = accessible
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        try XCTUnwrap(addStatus == errSecSuccess ? () : nil, "SecItemAdd failed for \(account): \(addStatus)")
    }
}
