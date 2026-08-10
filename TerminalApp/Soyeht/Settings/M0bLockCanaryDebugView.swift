#if DEBUG
import NetworkExtension
import Security
import SoyehtCore
import SwiftUI

/// M0b step-4 proof, run without Xcode/XCTest/USB attached (see
/// `docs/mesh-plan.md` M0b in theyos). The earlier measurement was taken
/// under an attached debug session, which itself kept protected data
/// available regardless of the physical lock — an invalid instrument. This
/// screen exists so the same canary can run from a normally-launched,
/// normally-installed app instead: tap Prepare, tap Start, lock the device
/// immediately, wait for the delay window to pass, then come back and tap
/// Refresh. `M0bLockCanaryURLTrigger` (AppDelegate.swift) drives the same
/// two actions from a single `soyeht://debug/m0b-lock-canary-start` open,
/// for when navigating here by hand isn't worth the risk of losing the
/// moment right before locking the device.
struct M0bLockCanaryDebugView: View {
    private let appGroupSuiteName = M0bLockCanaryConstants.appGroupSuiteName
    private let delaySeconds: Double = 60

    @State private var prepareStatus: String?
    @State private var startStatus: String?
    @State private var lastResult: [String: Any]?
    @State private var isBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Run in order: Prepare, then Start, then lock the phone with the side button immediately. Do not reopen Xcode or reconnect the cable until after the wait window. Come back after \(Int(delaySeconds))+ seconds, unlock, reopen this screen, and tap Refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    prepareStatus = Self.resultDescription(of: Result { try M0bLockCanaryActions.prepare() })
                } label: {
                    Label("1. Prepare canary items", systemImage: "key")
                }
                .disabled(isBusy)
                if let prepareStatus {
                    Text(prepareStatus).font(.footnote).monospaced()
                }

                Button {
                    Task {
                        isBusy = true
                        defer { isBusy = false }
                        do {
                            let status = try await M0bLockCanaryActions.start(delaySeconds: delaySeconds)
                            startStatus = "ok: \(status)"
                        } catch {
                            startStatus = "failed: \(error)"
                        }
                    }
                } label: {
                    Label("2. Start (lock the phone right after)", systemImage: "lock.rotation")
                }
                .disabled(isBusy)
                if let startStatus {
                    Text(startStatus).font(.footnote).monospaced()
                }

                Divider()

                Button {
                    refreshLastResult()
                } label: {
                    Label("Refresh last result", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)

                if let lastResult {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lastResult.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(String(describing: lastResult[key] ?? "nil"))")
                                .font(.footnote)
                                .monospaced()
                        }
                    }
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                } else {
                    Text("No result read yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("M0b Lock Canary")
        .onAppear { refreshLastResult() }
    }

    private func refreshLastResult() {
        lastResult = UserDefaults(suiteName: appGroupSuiteName)?.dictionary(forKey: M0bLockCanaryConstants.resultDefaultsKey)
    }

    private static func resultDescription<T>(of result: Result<T, Error>) -> String {
        switch result {
        case .success(let value):
            if value is Void { return "ok" }
            return "ok: \(value)"
        case .failure(let error):
            return "failed: \(error)"
        }
    }
}

/// Core actions shared between the debug screen above and
/// `M0bLockCanaryURLTrigger` in AppDelegate.swift, so both entry points run
/// exactly the same code — a UI-only path and a URL-only path silently
/// diverging is exactly the kind of gap this whole exercise exists to avoid.
enum M0bLockCanaryActions {
    static func prepare() throws {
        let accessGroup = try MeshTunnelKeychainAccessGroup.resolve(from: .main)
        try addCanaryItem(
            account: M0bLockCanaryConstants.whenUnlockedAccount,
            accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessGroup: accessGroup.value
        )
        try addCanaryItem(
            account: M0bLockCanaryConstants.afterFirstUnlockAccount,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            accessGroup: accessGroup.value
        )
        try addCanaryItem(
            account: M0bLockCanaryConstants.whenPasscodeSetAccount,
            accessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            accessGroup: accessGroup.value
        )
        try writeProtectedProbeFile()
        UserDefaults(suiteName: M0bLockCanaryConstants.appGroupSuiteName)?
            .removeObject(forKey: M0bLockCanaryConstants.resultDefaultsKey)
    }

    @discardableResult
    static func start(delaySeconds: Double) async throws -> String {
        guard let hostBundleID = Bundle.main.bundleIdentifier else {
            throw M0bLockCanaryError.hostBundleIdentifierUnavailable
        }
        let providerBundleID = "\(hostBundleID).SoyehtClawShareTunnelProvider"

        let existingManagers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = existingManagers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
        } ?? NETunnelProviderManager()

        let protocolConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = providerBundleID
        protocolConfiguration.serverAddress = "m0b-lock-canary"
        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = "M0b Lock Canary (no debugger)"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        try manager.connection.startVPNTunnel(options: [
            M0bLockCanaryConstants.canarySentinelKey: M0bLockCanaryConstants.canarySentinelValue as NSString,
            M0bLockCanaryConstants.canaryDelaySecondsKey: NSNumber(value: delaySeconds),
        ])
        return "status=\(manager.connection.status.rawValue)"
    }

    private static func addCanaryItem(account: String, accessible: CFString, accessGroup: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: M0bLockCanaryConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data("canary".utf8)
        addQuery[kSecAttrAccessible as String] = accessible
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw M0bLockCanaryError.keychainWriteFailed(account: account, status: status)
        }
    }

    private static func writeProtectedProbeFile() throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: M0bLockCanaryConstants.appGroupSuiteName
        ) else {
            throw M0bLockCanaryError.appGroupContainerUnavailable
        }
        let fileURL = containerURL.appendingPathComponent(M0bLockCanaryConstants.protectedFileName)
        try? FileManager.default.removeItem(at: fileURL)
        try Data("keybag-probe".utf8).write(to: fileURL, options: .completeFileProtection)
    }
}

/// Duplicates the handful of constants `M0bSmokeCheck` (extension target)
/// and `M0bProvisioningSmokeTests` (test target) already each define
/// independently — deliberate, matching that file's own convention: this
/// screen sits on the app-target side of the same host/extension boundary
/// being tested, so sharing a type across it would hide a real wiring
/// mismatch instead of catching one.
enum M0bLockCanaryConstants {
    static let canarySentinelKey = "com.soyeht.mobile.clawshare.m0bKeychainCanarySentinel"
    static let canarySentinelValue = "m0b-canary-2026-08-09"
    static let canaryDelaySecondsKey = "com.soyeht.mobile.clawshare.m0bKeychainCanaryDelaySeconds"
    static let keychainService = "com.soyeht.mobile.clawshare.m0bSmoke"
    static let whenUnlockedAccount = "canaryWhenUnlockedThisDeviceOnly"
    static let afterFirstUnlockAccount = "canaryAfterFirstUnlockThisDeviceOnly"
    static let whenPasscodeSetAccount = "canaryWhenPasscodeSetThisDeviceOnly"
    static let appGroupSuiteName = "group.com.soyeht.mobile.clawshare.dev"
    static let resultDefaultsKey = "m0bKeychainCanaryResult"
    static let protectedFileName = "m0b-keybag-probe.dat"
}

enum M0bLockCanaryError: Error {
    case keychainWriteFailed(account: String, status: OSStatus)
    case appGroupContainerUnavailable
    case hostBundleIdentifierUnavailable
}
#endif
