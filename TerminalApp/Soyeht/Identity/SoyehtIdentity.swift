import Foundation
import SoyehtCore
import SwiftUI
import UIKit
import os

private let identityLogger = Logger(subsystem: "com.soyeht.mobile", category: "soyeht-identity")

/// In-process, UI-facing source of truth for "does this iPhone have a
/// Soyeht identity?".
///
/// `SoyehtIdentity` is the single observable surface SwiftUI views
/// consume to ask:
///   - "Am I active?" → `isActive` / `state.isActive`
///   - "What is my Soyeht?" → `active` / `state.snapshot`
///   - "Who am I as an owner device?" → `thisDevice`
///
/// It is a thin facade over the existing Keychain-backed
/// `HouseholdSessionStore` and the per-process
/// `HouseholdSessionController`. Persistence, the cryptographic
/// `OwnerIdentityKey`, and protocol-level types (`ActiveHouseholdState`,
/// `PersonCert`, etc.) live *below* this facade and are not affected.
///
/// State resolution distinguishes three failure modes that the old
/// `try? store.load() != nil` pattern collapsed into a single Bool:
///
///   - `.unavailable(.protectedDataUnavailable)` — iPhone is locked,
///     Keychain unreadable. Auto-recovers via
///     `protectedDataDidBecomeAvailableNotification`.
///   - `.unavailable(.decodingFailed)` — Keychain entry exists but
///     malformed; logged loudly. UI may treat as `.inactive` but the
///     state remains distinct so a corrupted entry is never silently
///     interpreted as "no session".
///   - `.inactive` — confirmed absence of any local identity.
///
/// Out-of-band writes against `HouseholdSessionStore` (e.g.
/// `HouseholdPairingService` saving after a successful pair) must call
/// `SoyehtIdentity.shared.reload()` immediately afterward. Without
/// that, the facade stays stale until the next foreground transition.
@MainActor
final class SoyehtIdentity: ObservableObject {
    static let shared = SoyehtIdentity()

    /// Quad-state result of the most recent `reload()`. Published so
    /// SwiftUI views observing this object re-render on changes.
    @Published private(set) var state: SoyehtIdentityState = .unknown

    /// This iPhone/iPad as an owner-capable device. Always non-nil,
    /// even before a Soyeht identity exists (the Caso B setup
    /// invitation publishes the device id before pairing completes).
    let thisDevice: OwnerDevice

    // MARK: - Conveniences

    /// `nil` unless `state` is `.active`. Use for views that only
    /// render content when an identity exists.
    var active: SoyehtIdentitySnapshot? { state.snapshot }

    /// `true` iff `state` is `.active`. UI that needs to differentiate
    /// `.unavailable(.decodingFailed)` from `.inactive` must switch on
    /// `state` directly.
    var isActive: Bool { state.isActive }

    // MARK: - Dependencies

    private let store: HouseholdSessionStore
    private let controller: HouseholdSessionController
    private let isProtectedDataAvailable: () -> Bool
    private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Init

    /// Production singleton init. Wires:
    ///   - the same `HouseholdSessionStore` that `HouseholdSessionController.shared` reads,
    ///   - `PairedMacsStore.shared` for the device id (Keychain-backed),
    ///   - `UIDevice.current.name` for the human label,
    ///   - `UIApplication.shared.isProtectedDataAvailable` for the
    ///     lock-screen-aware state resolution.
    private convenience init() {
        let pairedMacsStore = PairedMacsStore.shared
        self.init(
            store: HouseholdSessionStore(),
            controller: HouseholdSessionController.shared,
            localPairingDeviceId: pairedMacsStore.ensureDeviceID(),
            deviceModel: pairedMacsStore.deviceModel,
            deviceDisplayName: UIDevice.current.name,
            isProtectedDataAvailable: { UIApplication.shared.isProtectedDataAvailable }
        )
    }

    /// Test-friendly init. Caller injects everything the facade
    /// touches so unit tests can simulate locked Keychain, decode
    /// failure, and the `protectedDataDidBecomeAvailable` cycle
    /// without UIKit.
    init(
        store: HouseholdSessionStore,
        controller: HouseholdSessionController,
        localPairingDeviceId: UUID,
        deviceModel: String,
        deviceDisplayName: String,
        isProtectedDataAvailable: @escaping () -> Bool
    ) {
        self.store = store
        self.controller = controller
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.thisDevice = OwnerDevice(
            localPairingDeviceId: localPairingDeviceId,
            displayName: deviceDisplayName,
            model: deviceModel,
            isThisDevice: true
        )
        installObservers()
        reload()
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Mutation API

    /// Synchronously resolves `state` from the current contents of
    /// the Keychain. Safe to call from any view code after an
    /// out-of-band write (e.g. `HouseholdSessionStore.save(...)`
    /// from `HouseholdPairingService`).
    ///
    /// Behaviour:
    ///   1. If protected data is unavailable → `.unavailable(.protectedDataUnavailable)`.
    ///   2. If `store.load()` returns `nil` → `.inactive`.
    ///   3. If `store.load()` returns a value → `.active(snapshot)`.
    ///   4. If `store.load()` throws `decodingFailed` → `.unavailable(.decodingFailed)` + loud log.
    func reload() {
        guard isProtectedDataAvailable() else {
            updateState(.unavailable(.protectedDataUnavailable))
            return
        }
        do {
            if let raw = try store.load() {
                updateState(.active(SoyehtIdentitySnapshot(raw: raw)))
            } else {
                updateState(.inactive)
            }
        } catch {
            identityLogger.error(
                "soyeht_diag identity_decode_failed error=\(String(describing: error), privacy: .public)"
            )
            updateState(.unavailable(.decodingFailed))
        }
    }

    /// Async refresh: delegates to `HouseholdSessionController` (which
    /// fetches the latest household snapshot from the engine and
    /// rewrites the Keychain entry on changes), then re-runs `reload()`
    /// so this facade picks up whatever the controller wrote.
    ///
    /// Use from `.task` / `.onChange(of: scenePhase)` in views. Cheap
    /// when nothing changed (controller is best-effort, no-ops on
    /// engine unreachable).
    func refresh() async {
        await controller.refresh()
        reload()
    }

    // MARK: - Internals

    /// Single mutation point for `state`. Avoids re-emitting
    /// `objectWillChange` when the resolved state is identical to the
    /// previous one (saves spurious SwiftUI redraws on every
    /// `.protectedDataDidBecomeAvailable` even when nothing changed).
    private func updateState(_ next: SoyehtIdentityState) {
        guard state != next else { return }
        state = next
    }

    /// Subscribes to the two external signals that can change the
    /// resolved state without an explicit `reload()` call:
    ///
    ///   - `protectedDataDidBecomeAvailableNotification` — promotes
    ///     `.unavailable(.protectedDataUnavailable)` to a definitive
    ///     `.active`/`.inactive` on first unlock.
    ///   - `HouseCreatedPushHandler.houseCreatedReceived` — fired when
    ///     the engine reports a fresh household creation push to this
    ///     device (existing fan-out used by `HomeViewState`).
    ///
    /// Both deliver on the main queue and dispatch the actual
    /// `reload()` back onto the `@MainActor` via a `Task`. Idempotent
    /// — re-installing would double the observers, but `init` runs
    /// once per instance.
    private func installObservers() {
        let center = NotificationCenter.default
        let unlock = center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
        let houseCreated = center.addObserver(
            forName: HouseCreatedPushHandler.houseCreatedReceived,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
        observerTokens = [unlock, houseCreated]
    }
}
