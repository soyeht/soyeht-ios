#if DEBUG
import Foundation
import NetworkExtension
import RelayStreamGuestFFI
import Security
import SoyehtCore
import os

/// M0b provisioning smoke test (see soyeht-plano.md M0b).
///
/// Proves, on a physical device, that the Network Extension entitlement, the
/// shared App Group, the shared Keychain Access Group, and the Rust XCFramework
/// all work from inside the extension process — without touching any real
/// tunnel/session logic. Dev-only, and only activates when a private sentinel
/// is present in the VPN start options, so an ordinary tunnel start can never
/// reach this path by accident.
enum M0bSmokeCheck {
    static let sentinelKey = "com.soyeht.mobile.clawshare.m0bSmokeSentinel"
    static let sentinelValue = "m0b-2026-08-08"
    static let keychainService = "com.soyeht.mobile.clawshare.m0bSmoke"
    static let keychainAccount = "smokeValue"
    static let appGroupSuiteName = "group.com.soyeht.mobile.clawshare.dev"
    static let resultDefaultsKey = "m0bSmokeResult"

    /// M4-premise canary (see soyeht-plano.md M4): proves which
    /// `kSecAttrAccessible*` class survives a genuine, physically-locked
    /// device from inside this extension. Two items, two classes, real
    /// OSStatus values reported — no interpretation, no "did it read a
    /// string" ambiguity.
    static let canarySentinelKey = "com.soyeht.mobile.clawshare.m0bKeychainCanarySentinel"
    static let canarySentinelValue = "m0b-canary-2026-08-09"
    static let canaryWhenUnlockedAccount = "canaryWhenUnlockedThisDeviceOnly"
    static let canaryAfterFirstUnlockAccount = "canaryAfterFirstUnlockThisDeviceOnly"
    static let canaryWhenPasscodeSetAccount = "canaryWhenPasscodeSetThisDeviceOnly"
    static let canaryResultDefaultsKey = "m0bKeychainCanaryResult"
    static let canaryProtectedFileName = "m0b-keybag-probe.dat"

    /// Optional `NSNumber` (seconds) in the start options. See
    /// `docs/mesh-plan.md`'s M0b step-4 note in theyos: the only measurement
    /// taken so far was under an attached XCTest/debugger/USB context, which
    /// itself kept protected data available regardless of the physical lock
    /// — an invalid instrument, not a real answer. Removing that whole
    /// context means the HOST app can no longer just `Task.sleep` across the
    /// lock window itself, since a plain backgrounded app is liable to be
    /// suspended the moment the screen locks. A `NEPacketTunnelProvider`
    /// that has already reported itself connected is exactly the kind of
    /// long-lived background process iOS keeps running, so the wait moves
    /// here: the host starts the tunnel (still unlocked), this returns
    /// success immediately so NetworkExtension has no reason to tear the
    /// extension down, and the actual Keychain read happens later, from a
    /// detached Task, after the caller has had time to lock the device for
    /// real.
    static let canaryDelaySecondsKey = "com.soyeht.mobile.clawshare.m0bKeychainCanaryDelaySeconds"

    /// Returns `.handled(error:)` if this was a smoke-check start — `error` is
    /// nil on success (report success to NetworkExtension so the extension
    /// process isn't torn down as a failed connection before its App Group
    /// write is observed) or a real error on genuine failure. Returns `.none`
    /// if the real tunnel logic should run instead.
    enum Outcome {
        case handled(error: Error?)
        case none
    }

    static func runIfRequested(
        options: [String: NSObject]?,
        logger: Logger
    ) -> Outcome {
        if let canarySentinel = options?[canarySentinelKey] as? String, canarySentinel == canarySentinelValue {
            let rawDelaySeconds = (options?[canaryDelaySecondsKey] as? NSNumber)?.doubleValue ?? 0
            guard rawDelaySeconds > 0 else {
                return runKeychainAccessibilityCanary(logger: logger)
            }
            // `delaySeconds` comes from a URL query string with no upstream
            // validation — `.isFinite` rejects NaN/inf (Double("inf") parses
            // successfully and is `> 0`), and the cap keeps a fat-fingered
            // huge value from doing anything worse than a long wait. Without
            // both, `UInt64(delaySeconds * 1e9)` below traps: the non-failable
            // `UInt64(_:)` initializer aborts the process on out-of-range or
            // non-finite input, unlike `UInt64(exactly:)`.
            guard rawDelaySeconds.isFinite else {
                return .handled(error: M0bSmokeCheckFailed(reason: "canary_delay_seconds_not_finite"))
            }
            let delaySeconds = min(rawDelaySeconds, 3600)
            let waitStartedAt = Date()
            // Diagnostic checkpoint distinct from the immediate-path result,
            // so a poll landing mid-wait can tell "extension launched and is
            // waiting for the lock window" apart from "extension never
            // launched at all" or "already wrote the real answer."
            writeCanaryWaitingCheckpoint(delaySeconds: delaySeconds, waitStartedAt: waitStartedAt)
            logger.info("m0b_keychain_canary_delayed_wait_started")
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                _ = runKeychainAccessibilityCanary(logger: logger, trigger: "delayed", waitStartedAt: waitStartedAt)
            }
            return .handled(error: nil)
        }

        guard let sentinel = options?[sentinelKey] as? String, sentinel == sentinelValue else {
            return .none
        }

        // Diagnostic checkpoint: written immediately, before any Keychain or
        // FFI work, and overwritten below once real steps are known. `done:
        // false` keeps this from ever satisfying pollForResult on its own —
        // it exists to be inspected manually (or by a future diagnostic
        // that explicitly wants it), not to be picked up as the answer. If
        // execution never reaches the real write below, the App Group value
        // stays at this checkpoint forever, which is itself the signal that
        // something got stuck (or crashed silently) after entering here.
        writeResult(steps: ["entered_runIfRequested"], failure: nil, done: false)

        var steps: [String] = []
        var failure: String?

        if let value = readKeychainValue() {
            steps.append("keychain_read_ok:\(value)")
            logger.info("m0b_smoke_keychain_read_ok")
        } else {
            failure = "keychain_read_failed"
            logger.error("m0b_smoke_keychain_read_failed")
        }

        if failure == nil {
            do {
                _ = try relayStreamRendezvousHelloBytes(offerCbor: Data())
                failure = "ffi_call_should_have_thrown"
                logger.error("m0b_smoke_ffi_call_should_have_thrown")
            } catch RelayStreamGuestError.Offer {
                steps.append("ffi_call_ok")
                logger.info("m0b_smoke_ffi_call_ok")
            } catch {
                failure = "ffi_call_unexpected_error"
                logger.error("m0b_smoke_ffi_call_unexpected_error")
            }
        }

        writeResult(steps: steps, failure: failure)
        if let failure {
            return .handled(error: M0bSmokeCheckFailed(reason: failure))
        }
        return .handled(error: nil)
    }

    /// Reads both canary items and reports raw `OSStatus` values only — the
    /// test caller compares these against `errSecInteractionNotAllowed`
    /// (-25308) and `errSecSuccess`, so there is nothing here to
    /// misinterpret as "read worked" when it actually didn't. `trigger`
    /// records which path produced the result — "immediate" (the original,
    /// XCTest-attached path) vs "delayed" (detached-Task path, meant to run
    /// with no debugger/USB attached) — but `trigger` alone only says which
    /// CODE PATH ran, not whether the device was actually locked when it
    /// ran: a human who unlocks before tapping "Refresh" (the documented
    /// workflow) can't tell a genuinely-locked read from one that landed
    /// after unlock just by looking at `trigger`. `waitStartedAt`, when
    /// given, is carried into the result so that evidence survives instead
    /// of being overwritten by this function's own `defaults.set` — without
    /// it, nothing could later prove the delay actually elapsed.
    /// `instrumentValid` is the same fail-fast signal
    /// `M0bProvisioningSmokeTests.testKeychainAccessibilityCanaryUnderLock`
    /// already applies via `protectedFileReadable`: `false` here means what
    /// invalidated the very first measurement of this canary (protected data
    /// staying available despite a real physical lock) may be happening
    /// again, and the OSStatus values below should not be trusted.
    private static func runKeychainAccessibilityCanary(
        logger: Logger,
        trigger: String = "immediate",
        waitStartedAt: Date? = nil
    ) -> Outcome {
        guard let accessGroup = try? MeshTunnelKeychainAccessGroup.resolve(from: .main) else {
            return .handled(error: M0bSmokeCheckFailed(reason: "canary_access_group_unresolved"))
        }

        func status(forAccount account: String) -> OSStatus {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup.value,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            return SecItemCopyMatching(query as CFDictionary, &result)
        }

        let whenUnlockedStatus = status(forAccount: canaryWhenUnlockedAccount)
        let afterFirstUnlockStatus = status(forAccount: canaryAfterFirstUnlockAccount)
        let whenPasscodeSetStatus = status(forAccount: canaryWhenPasscodeSetAccount)
        logger.info("m0b_keychain_canary_read")

        // Non-Keychain observable of the keybag: a FileProtectionType.complete
        // file, created and closed by the HOST app before lock, read here in
        // the EXTENSION's own separate process after lock — the two are
        // distinct processes sharing the App Group container, not the same
        // process. This isolates "the keybag genuinely isn't locking in this
        // context" from "something Keychain-specific is wrong" — no
        // interaction with SecItem* at all.
        var protectedFileReadable = false
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupSuiteName
        ) {
            let fileURL = containerURL.appendingPathComponent(canaryProtectedFileName)
            protectedFileReadable = (try? Data(contentsOf: fileURL)) != nil
        }

        guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else {
            return .handled(error: M0bSmokeCheckFailed(reason: "canary_app_group_unavailable"))
        }
        let now = Date()
        var result: [String: Any] = [
            "whenUnlockedStatus": Int(whenUnlockedStatus),
            "afterFirstUnlockStatus": Int(afterFirstUnlockStatus),
            "whenPasscodeSetStatus": Int(whenPasscodeSetStatus),
            "protectedFileReadable": protectedFileReadable,
            "instrumentValid": !protectedFileReadable,
            "trigger": trigger,
            "done": true,
            "timestamp": now.timeIntervalSince1970,
        ]
        if let waitStartedAt {
            result["waitStartedAt"] = waitStartedAt.timeIntervalSince1970
            result["waitElapsedSeconds"] = now.timeIntervalSince(waitStartedAt)
        }
        defaults.set(result, forKey: canaryResultDefaultsKey)
        return .handled(error: nil)
    }

    private static func writeCanaryWaitingCheckpoint(delaySeconds: Double, waitStartedAt: Date) {
        guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else { return }
        defaults.set(
            [
                "waiting": true,
                "delaySeconds": delaySeconds,
                "waitStartedAt": waitStartedAt.timeIntervalSince1970,
                "done": false,
                "timestamp": Date().timeIntervalSince1970,
            ],
            forKey: canaryResultDefaultsKey
        )
    }

    private static func readKeychainValue() -> String? {
        guard let accessGroup = try? MeshTunnelKeychainAccessGroup.resolve(from: .main) else {
            return nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: accessGroup.value,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `done: false` marks the diagnostic checkpoint (written before any
    /// real work, so an observer seeing exactly this and nothing more means
    /// execution got stuck between here and the real write); `done: true`
    /// marks the actual result. Both go through the same key so the
    /// checkpoint keeps its diagnostic value, but `pollForResult` on the
    /// test side must wait for `done: true` specifically — otherwise a poll
    /// landing between the checkpoint and the final write reads the
    /// checkpoint as if it were the answer.
    private static func writeResult(steps: [String], failure: String?, done: Bool = true) {
        guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else { return }
        // `failure as Any` when `failure == nil` boxes an Optional inside
        // Any, which isn't a valid property-list value — CFPreferences
        // aborts the process on that instead of failing silently. Omitting
        // the key on the nil case keeps every value in this dictionary a
        // genuine plist type.
        var result: [String: Any] = [
            "steps": steps,
            "done": done,
            "timestamp": Date().timeIntervalSince1970,
        ]
        if let failure {
            result["failure"] = failure
        }
        defaults.set(
            result,
            forKey: resultDefaultsKey
        )
    }
}

struct M0bSmokeCheckFailed: Error {
    let reason: String
}
#endif
