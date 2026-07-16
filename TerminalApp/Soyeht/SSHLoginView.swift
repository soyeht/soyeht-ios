import SwiftUI
import SoyehtCore
import SwiftTerm
import UIKit
import os

// MARK: - Debug Bootstrap Configuration

private enum DebugBootstrapConfig {
    private static let secrets: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            return [:]
        }
        return dict
    }()

    static let apiHost = secrets["SimulatorAPIHost"] as? String ?? ""
    static let sessionToken = secrets["SimulatorSessionToken"] as? String ?? ""
    static let expiresAt = secrets["SimulatorExpiresAt"] as? String ?? ""
}

private let householdAPNSLogger = Logger(subsystem: "com.soyeht.mobile", category: "household-apns-registration")
private let householdDeepLinkLogger = Logger(subsystem: "com.soyeht.mobile", category: "household-deep-link")
private let householdLifecycleLogger = Logger(subsystem: "com.soyeht.mobile", category: "household-lifecycle")

/// Sheet payload for the deep-link `soyeht://household/pair-device`
/// confirmation gate. The reason this gate exists is captured at the
/// call site in `handleIncomingDeepLink`; this struct is just the
/// `Identifiable` glue so SwiftUI's `.sheet(item:)` can route it.
fileprivate struct PendingPairDeviceConfirmation: Identifiable {
    let id = UUID()
    let url: URL
    let fingerprintWords: [String]
}

/// Derive the BLAKE3 -> BIP-39 fingerprint words from a
/// `soyeht://household/pair-device` or `/device-pairing` URL.
///
/// SAFETY contract for the deep-link path: if this throws, the caller
/// MUST refuse to pair — the fingerprint is the operator's only line
/// of defence on a URL delivered by an untrusted sender (any installed
/// app can call `UIApplication.open` on a `soyeht://` URL once the
/// scheme is registered). Concretely, the function throws when:
/// 1. The pair-device or device-pairing parser rejects the URL (would
///    only happen if the dispatcher contract upstream changes).
/// 2. `BIP39Wordlist()` cannot load its bundled resource (corrupted
///    app bundle).
/// 3. `OperatorFingerprint.derive(...)` fails on a degenerate
///    `householdPublicKey` (would only happen if `PairDeviceQR` itself
///    returned a malformed `Data` — defensive third check).
///
/// Extracted as a top-level function so the SwiftUI view layer keeps a
/// thin bridging role and the security-critical parse + derive logic
/// is unit-testable without spinning up the full `SoyehtAppView`.
/// Closes PR #61 review NIT #8.
internal func pairDeviceFingerprintWords(
    for url: URL,
    now: Date
) throws -> [String] {
    let householdPublicKey: Data
    let pairingNonce: Data
    if SelfContainedPairingURL.isHouseholdDevicePairing(url) {
        let link = try HouseholdDevicePairingLink(url: url)
        householdPublicKey = link.householdPublicKey
        pairingNonce = link.pairingNonce
    } else {
        let qr = try PairDeviceQR(url: url, now: now)
        householdPublicKey = qr.householdPublicKey
        pairingNonce = qr.nonce
    }
    let wordlist = try BIP39Wordlist()
    let fingerprint = try OperatorFingerprint.derive(
        machinePublicKey: householdPublicKey,
        pairingNonce: pairingNonce,
        wordlist: wordlist
    )
    return fingerprint.words
}

private enum SelfContainedPairingURL {
    static func isHouseholdDevicePairing(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "soyeht"
            && components.host == "household"
            && components.path == "/device-pairing"
    }
}

/// The recovery flow may display an authenticated base machine, but that
/// identity-only projection must never make the app enter an operational
/// instance flow. Only entries backed by an existing credential/route adapter
/// count when choosing between the household home and the instance list.
@MainActor
enum HouseholdRecoveryDestination: Equatable {
    case householdHome
    case instanceList

    static func resolve(registry: ServerRegistry) -> Self {
        registry.operationalServers.isEmpty ? .householdHome : .instanceList
    }
}

/// A return path must never treat a visible base-machine projection as an
/// operational instance. The household home owns display-only identity context;
/// the instance list remains reserved for credential-backed server adapters.
@MainActor
enum HomeFallbackDestination: Equatable {
    case noHome
    case householdHome
    case instanceList

    static func resolve(
        registry: ServerRegistry,
        hasActiveHousehold: Bool
    ) -> Self {
        if !registry.operationalServers.isEmpty {
            return .instanceList
        }
        return hasActiveHousehold ? .householdHome : .noHome
    }
}

// MARK: - App Root View

struct SoyehtAppView: View {
    @State private var appState: SoyehtAppRoute = .splash
    @State private var autoSelectInstance: SoyehtInstance?
    @State private var autoSelectServerId: String?
    @State private var autoSelectSessionName: String?
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var lastHandledDeepLink = ""
    @State private var lastHandledDeepLinkAt = Date.distantPast
    @State private var themeRevision = 0
    @State private var showSettings = false
    /// US-F: presented from InstanceList's "+" so users get a Linux pairing
    /// guide (and a clear "I already have a link" branch) instead of being
    /// dumped straight into the QR scanner with no instructions.
    @State private var showAddDeviceSheet = false
    /// Set when a `soyeht://household/pair-device` deep link arrives via
    /// `scene(_:openURLContexts:)` on a device that has no active
    /// household yet. Triggers the confirmation sheet — see
    /// `handleIncomingDeepLink` for why this gate exists.
    @State private var pendingPairDeviceConfirmation: PendingPairDeviceConfirmation?
    @State private var macLocalPairingPublisher: SetupInvitationPublisher?
    /// Mirrors the active pair-device flow regardless of source (deep link
    /// or in-app camera). Set true when the operator commits to a pair
    /// (camera scan accepted, or sheet "pair as owner" tapped) and reset
    /// when the pair completes — success or failure. Guards against a
    /// second pair URL racing into a parallel `HouseholdPairingService.pair`
    /// call before the first has written the identity snapshot that
    /// `SoyehtIdentity` exposes. The dispatcher's
    /// `activeHouseholdId == nil` gate only sees persisted state, so it
    /// cannot block in-flight overlap on its own.
    @State private var isPairing = false
    @StateObject private var machineJoinRuntime = HouseholdMachineJoinRuntime()
    @ObservedObject private var macsStoreBox = PairedMacsStoreObservable.shared
    @ObservedObject private var identity = SoyehtIdentity.shared
    /// Drives the "your home isn't set up yet" banner overlaid on the
    /// `.qrScanner` case. `HomeViewState` is `@MainActor` and publishes
    /// `noHouseholdBannerVisible` derived from `parking_lot_visited_at`
    /// (AppStorage, written by `AppDelegate.showParkingLot`) and
    /// `SoyehtIdentity`. Auto-clears via the
    /// `HouseCreatedPushHandler.houseCreatedReceived` observer wired
    /// inside `HomeViewState.init`.
    @StateObject private var homeViewState = HomeViewState()

    private let store = SessionStore.shared
    private let apiClient = SoyehtAPIClient.shared
    private var homeFallbackRoute: SoyehtAppRoute? {
        let snapshot = identity.active
        switch HomeFallbackDestination.resolve(
            registry: ServerRegistry.shared,
            hasActiveHousehold: snapshot != nil
        ) {
        case .noHome:
            return nil
        case .householdHome:
            guard let snapshot else { return nil }
            return .householdHome(snapshot)
        case .instanceList:
            return .instanceList
        }
    }

    private var hasHomeContent: Bool {
        homeFallbackRoute != nil
    }
    // The QR dispatcher only needs the persisted identity id. Read it
    // through `SoyehtIdentity` so this view does not hit
    // `HouseholdSessionStore` directly on every body re-evaluation.
    private var activeHouseholdId: String? {
        identity.active?.id
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            switch appState {
            case .splash:
                SplashView {
                    Task { await handlePostSplash() }
                }
                .transition(.opacity)

            case .qrScanner:
                ZStack(alignment: .top) {
                    QRScannerView(
                    // Always offer a back path. When the user already has
                    // paired servers/macs/household we go back to the home
                    // list; otherwise we hop back into the install picker
                    // so first-time users are never stranded on the camera.
                    showsCancel: true,
                    activeHouseholdId: activeHouseholdId,
                    onScanned: { result, url in
                        // Camera-path equivalent of the deep-link
                        // `isPairing` early-return: drop a second
                        // `householdPairDevice` scan while one is
                        // already in flight rather than spinning up
                        // a parallel `HouseholdPairingService.pair`
                        // Task. Bounded threat (camera requires
                        // deliberate user action), but a confused
                        // double-scan would otherwise race the same
                        // way two attacker URLs can on the deep-link
                        // path. Other QR types (server pair, machine
                        // join, local handoff) are unaffected — they
                        // have their own in-flight semantics.
                        //
                        // Why no `pendingPairDeviceConfirmation` check
                        // here (unlike the deep-link branch): when the
                        // sheet is presented `appState` is still
                        // `.qrScanner` but SwiftUI's modal cover
                        // intercepts taps, so the user cannot reach
                        // the camera button at all. Re-evaluate this
                        // assumption if the sheet ever moves to a
                        // non-modal presenter (e.g. a banner or a
                        // sibling NavigationStack destination).
                        if (isHouseholdPairingScan(result)) && isPairing {
                            householdDeepLinkLogger.info(
                                "dropping concurrent camera-path household pair scan; pair already in flight url=\(url?.absoluteString ?? "<nil>", privacy: .sensitive)"
                            )
                            return
                        }
                        Task { await handleQRScanned(result: result, sourceURL: url) }
                    },
                    onCancel: {
                        if let destination = homeFallbackRoute {
                            withAnimation { appState = destination }
                        } else {
                            // First-time user reached the scanner via the
                            // Linux pairing path (or a cold-launch fallback);
                            // hand control back to SceneDelegate so it can
                            // swap the window root to InstallPickerView.
                            NotificationCenter.default.post(
                                name: .soyehtRequestInstallPicker,
                                object: nil
                            )
                        }
                    }
                )

                    // "Your home isn't set up yet" banner — overlaid only
                    // when the user has no servers/macs/household AND has
                    // visited the LaterParkingLotView (i.e. they explicitly
                    // deferred setup via the InstallPicker "Get link later"
                    // path). Tapping reuses the existing
                    // `.soyehtRequestInstallPicker` notification that
                    // SceneDelegate observes to swap the window root back
                    // to InstallPickerView. Keeps the user one tap away
                    // from resuming canonical onboarding instead of being
                    // stranded on a bare QR scanner. Padding mirrors the
                    // scanner's own top-safe-area inset so the banner sits
                    // just below the notch / Dynamic Island without
                    // overlapping the cancel button.
                    if !hasHomeContent && homeViewState.noHouseholdBannerVisible {
                        NoHouseholdBanner(onSetupNow: {
                            NotificationCenter.default.post(
                                name: .soyehtRequestInstallPicker,
                                object: nil
                            )
                        })
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .transition(.opacity)

            case .householdHome(let snapshot):
                HouseholdHomeView(
                    household: snapshot.underlying,
                    machineJoinRuntime: machineJoinRuntime,
                    onAdd: {
                        withAnimation { appState = .qrScanner }
                    },
                    onSettings: {
                        showSettings = true
                    }
                )
                .onAppear {
                    startHouseholdMacRecoveryInvitation(for: snapshot)
                }
                .transition(.opacity)

            case .pairingSuccess(let snapshot):
                PairingSuccessView(
                    houseName: snapshot.displayName,
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .enrollOwnerPasskey(snapshot)
                        }
                    }
                )
                .transition(.opacity)

            case .enrollOwnerPasskey(let snapshot):
                // Fresh-onboarding owner passkey enrollment. Both completion and
                // an explicit "set up later" advance to the recovery message — the
                // existing next step — so enrollment never blocks the flow.
                OwnerPasskeyEnrollmentView(
                    snapshot: snapshot,
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .recoveryMessage(snapshot)
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .recoveryMessage(snapshot)
                        }
                    }
                )
                .transition(.opacity)

            case .recoveryMessage(let snapshot):
                RecoveryMessageView(
                    onDismiss: {
                        let household = snapshot.underlying
                        machineJoinRuntime.activate(household)
                        Task { @MainActor in
                            // The self/base engine did not arrive through the
                            // legacy HMAC Mac pairing flow. Resolve its
                            // owner-authenticated identity before choosing the
                            // empty-household route so it can render as the
                            // initial owned instance when available.
                            await BaseMachineProjector.shared.refresh()
                            withAnimation(.easeInOut(duration: 0.3)) {
                                switch HouseholdRecoveryDestination.resolve(registry: ServerRegistry.shared) {
                                case .householdHome:
                                    appState = .householdHome(snapshot)
                                case .instanceList:
                                    PairedMacRegistry.shared.reconcileClients()
                                    restoreNavigationIfNeeded()
                                    appState = .instanceList
                                }
                            }
                        }
                    }
                )
                .transition(.opacity)

            case .instanceList:
                ZStack(alignment: .top) {
                    InstanceListView(
                        onConnect: { wsUrl, instance, sessionName, context in
                            store.saveNavigationState(NavigationState(
                                serverId: context.serverId,
                                instanceId: instance.id,
                                sessionName: sessionName,
                                savedAt: Date()
                            ))
                            withAnimation(.easeInOut(duration: 0.3)) {
                                appState = .terminal(wsUrl: wsUrl, instance, sessionName: sessionName, context: context)
                            }
                        },
                        onHouseholdConnect: { request, instance, sessionName, serverId, endpoint in
                            store.saveNavigationState(NavigationState(
                                serverId: serverId,
                                instanceId: instance.id,
                                sessionName: sessionName,
                                savedAt: Date()
                            ))
                            withAnimation(.easeInOut(duration: 0.3)) {
                                appState = .householdTerminal(
                                    request: request,
                                    instance,
                                    sessionName: sessionName,
                                    serverId: serverId,
                                    endpoint: endpoint
                                )
                            }
                        },
                        onAddInstance: {
                            showAddDeviceSheet = true
                        },
                        onLogout: {
                            Task {
                                if let active = store.activeServerId,
                                   let ctx = store.context(for: active) {
                                    try? await apiClient.logout(context: ctx)
                                }
                                withAnimation { appState = .qrScanner }
                            }
                        },
                        onAttachMacPane: { macID, pane in
                            await attachToMacPane(macID: macID, pane: pane)
                        },
                        autoSelectInstance: $autoSelectInstance,
                        autoSelectServerId: $autoSelectServerId,
                        autoSelectSessionName: $autoSelectSessionName
                    )

                    if let snapshot = identity.active {
                        HouseholdDevicePairRequestOverlay(
                            household: snapshot.underlying,
                            machineJoinRuntime: machineJoinRuntime
                        )
                        .frame(maxWidth: .infinity, alignment: .top)
                        .zIndex(3)
                    }
                }
                .transition(.opacity)

            case .terminal(let wsUrl, let instance, let sessionName, let context):
                TerminalContainerView(
                    wsUrl: wsUrl,
                    instance: instance,
                    sessionName: sessionName,
                    context: context,
                    onDisconnect: {
                        autoSelectInstance = instance
                        autoSelectServerId = context.serverId
                        autoSelectSessionName = sessionName
                        store.clearNavigationState()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .instanceList
                        }
                    },
                    onConnectionLost: {
                        autoSelectInstance = instance
                        autoSelectServerId = context.serverId
                        autoSelectSessionName = sessionName
                        store.clearNavigationState()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .instanceList
                        }
                    }
                )
                .transition(.opacity)

            case .householdTerminal(let request, let instance, let sessionName, let serverId, let endpoint):
                HouseholdTerminalContainerView(
                    request: request,
                    instance: instance,
                    sessionName: sessionName,
                    onDisconnect: {
                        autoSelectInstance = instance
                        autoSelectServerId = serverId
                        autoSelectSessionName = sessionName
                        store.clearNavigationState()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .instanceList
                        }
                    },
                    onConnectionLost: {
                        autoSelectInstance = instance
                        autoSelectServerId = serverId
                        autoSelectSessionName = sessionName
                        store.clearNavigationState()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .instanceList
                        }
                    },
                    attachRequestRefresher: Self.makeHouseholdAttachRequestRefresher(
                        endpoint: endpoint,
                        container: instance.container,
                        workspaceId: sessionName
                    )
                )
                .transition(.opacity)

            case .localTerminal(let wsUrl, let title, let macID, let paneID):
                LocalTerminalContainerView(
                    wsUrl: wsUrl,
                    title: title,
                    onDisconnect: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = homeFallbackRoute ?? .qrScanner
                        }
                    },
                    onConnectionLost: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = homeFallbackRoute ?? .qrScanner
                        }
                    },
                    attachURLRefresher: Self.makeAttachRefresher(macID: macID, paneID: paneID)
                )
                .transition(.opacity)

            case .relayStreamOpening(let invite):
                RelayStreamOpeningView(
                    invite: invite,
                    onOpened: { configuration in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .relayStreamTerminal(configuration)
                        }
                    },
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = homeFallbackRoute ?? .qrScanner
                        }
                    }
                )
                .transition(.opacity)

            case .relayStreamTerminal(let configuration):
                RelayStreamTerminalContainerView(
                    configuration: configuration,
                    onDisconnect: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = homeFallbackRoute ?? .qrScanner
                        }
                    },
                    onConnectionLost: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = homeFallbackRoute ?? .qrScanner
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .overlay {
            if let message = successMessage {
                ConnectionSuccessOverlay(message: message)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(SoyehtTheme.preferredColorScheme)
        .onReceive(store.$pendingDeepLink.compactMap { $0 }) { url in
            handleIncomingDeepLink(url)
        }
        .onReceive(macsStoreBox.$macs) { macs in
            guard !macs.isEmpty else { return }
            switch appState {
            case .householdHome, .pairingSuccess, .recoveryMessage:
                PairedMacRegistry.shared.reconcileClients()
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState = .instanceList
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtColorThemeChanged)) { _ in
            themeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtDeepLink)) { notification in
            guard let url = notification.object as? URL else { return }
            handleIncomingDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if let identity = loadActiveIdentityForLifecycle(reason: "didBecomeActive") {
                machineJoinRuntime.activate(identity.underlying)
            }
            machineJoinRuntime.enterForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            machineJoinRuntime.enterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            // Cold-launch from a deep link with a passcode-locked device:
            // `handleIncomingDeepLink` runs before the keychain is
            // decryptable, the early-return defers the URL via
            // `store.pendingDeepLink`, and this observer replays the URL
            // the moment iOS reports protected data is available again.
            // The deferred branch in `handleIncomingDeepLink` keeps
            // `lastHandledDeepLink` untouched so this replay is not
            // suppressed by the 1 s dedup window. Closes PR #61 review
            // OPTIONAL #5.
            identity.reload()
            if let url = store.pendingDeepLink {
                handleIncomingDeepLink(url)
            }
        }
        .alert("error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            SettingsRootView()
        }
        .sheet(item: $pendingPairDeviceConfirmation) { confirmation in
            PairDeviceConfirmationSheet(
                fingerprintWords: confirmation.fingerprintWords,
                onConfirm: {
                    let url = confirmation.url
                    pendingPairDeviceConfirmation = nil
                    householdDeepLinkLogger.info(
                        "pair-device user confirmed; firing pair flow url=\(url.absoluteString, privacy: .sensitive)"
                    )
                    Task {
                        await handlePairDevice(
                            url: url,
                            keyProvider: SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
                        )
                    }
                },
                onCancel: {
                    let url = confirmation.url
                    pendingPairDeviceConfirmation = nil
                    householdDeepLinkLogger.info(
                        "pair-device user cancelled url=\(url.absoluteString, privacy: .sensitive)"
                    )
                }
            )
        }
        .sheet(isPresented: $showAddDeviceSheet) {
            AddDevicePickerView(
                onScanPairingLink: {
                    showAddDeviceSheet = false
                    withAnimation { appState = .qrScanner }
                },
                onDismiss: { showAddDeviceSheet = false }
            )
        }
    }

    // MARK: - Navigation Restoration

    private func presentPairDeviceConfirmation(for url: URL) {
        do {
            let words = try pairDeviceFingerprintWords(for: url, now: Date())
            #if DEBUG
            if shouldAutoConfirmPairDeviceURLInDebug(url) {
                isPairing = true
                householdDeepLinkLogger.info(
                    "pair-device debug auto-confirm requested; firing pair flow url=\(url.absoluteString, privacy: .sensitive)"
                )
                Task {
                    await handlePairDevice(
                        url: url,
                        keyProvider: SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
                    )
                }
                return
            }
            #endif
            pendingPairDeviceConfirmation = PendingPairDeviceConfirmation(
                url: url,
                fingerprintWords: words
            )
            householdDeepLinkLogger.info(
                "pair-device confirmation sheet presented; awaiting operator decision url=\(url.absoluteString, privacy: .sensitive)"
            )
        } catch {
            // Refuse to pair when the fingerprint cannot be derived — the
            // fingerprint is the operator's only line of defence on the
            // deep-link path. Log the technical reason for triage and
            // surface a user-visible toast so the failure does not
            // present as "the link did nothing." Closes PR #61 review
            // OPTIONAL #6.
            householdDeepLinkLogger.error(
                "pair-device fingerprint derive failed (refusing to pair): \(String(describing: error), privacy: .public)"
            )
            errorMessage = String(localized: LocalizedStringResource(
                "household.pairDevice.deriveFailed",
                defaultValue: "Could not verify the pairing link. Please re-open the QR scanner and try again.",
                comment: "User-visible error shown when a pair-device deep link arrives but the fingerprint cannot be derived (corrupted bundle or malformed URL). The deep-link path refuses to pair without a fingerprint to display because the fingerprint is the operator's only line of defence."
            ))
        }
    }

    #if DEBUG
    private func shouldAutoConfirmPairDeviceURLInDebug(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.queryItems?.contains {
            $0.name == "soyeht_debug_autoconfirm" && $0.value == "1"
        } == true
    }
    #endif

    private func handlePairDevice(
        url: URL,
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider()
    ) async {
        await MainActor.run { isPairing = true }
        do {
            let household = try await HouseholdPairingService(keyProvider: keyProvider).pair(
                url: url,
                displayName: await MainActor.run { HouseholdOwnerDisplayName.defaultName() }
            )
            do {
                _ = try await APNSRegistrationCoordinator.shared.handleSessionActivated()
            } catch {
                householdAPNSLogger.error("APNS registration after household pairing failed: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run {
                // `HouseholdPairingService.pair` wrote a fresh
                // `ActiveHouseholdState` directly to the Keychain; pull
                // it into the facade so observers of
                // `SoyehtIdentity.state` see the new identity on the
                // very next layout pass instead of waiting for the
                // landing view's `.task { identity.refresh() }`.
                SoyehtIdentity.shared.reload()
                isPairing = false
                machineJoinRuntime.activate(household)
                let snapshot = SoyehtIdentitySnapshot(raw: household)
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState = .pairingSuccess(snapshot)
                }
            }
        } catch let error as HouseholdPairingError {
            await MainActor.run {
                isPairing = false
                errorMessage = pairingMessage(for: error)
            }
        } catch {
            await MainActor.run {
                isPairing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleDevicePairing(
        url: URL,
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
    ) async {
        await MainActor.run { isPairing = true }
        do {
            let link = try HouseholdDevicePairingLink(url: url)
            await MainActor.run {
                startDevicePairingSetupInvitation(for: link)
            }
            let household = try await HouseholdDevicePairingService(keyProvider: keyProvider).pair(link: link)
            do {
                _ = try await APNSRegistrationCoordinator.shared.handleSessionActivated()
            } catch {
                householdAPNSLogger.error("APNS registration after device pairing failed: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run {
                // Pair-device wrote a fresh `ActiveHouseholdState` into
                // the Keychain — pull it into the facade so observers
                // of `SoyehtIdentity.state` reflect the new identity
                // immediately.
                SoyehtIdentity.shared.reload()
                isPairing = false
                machineJoinRuntime.activate(household)
                let snapshot = SoyehtIdentitySnapshot(raw: household)
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState = .pairingSuccess(snapshot)
                }
            }
        } catch {
            await MainActor.run {
                stopMacLocalPairingPublisher()
                isPairing = false
                errorMessage = devicePairingMessage(for: error)
            }
        }
    }

    @MainActor
    private func startDevicePairingSetupInvitation(for link: HouseholdDevicePairingLink) {
        startMacLocalPairingPublisher { claim in
            Self.devicePairingClaim(claim, matches: link)
        }
    }

    @MainActor
    private func startHouseholdMacRecoveryInvitation(for snapshot: SoyehtIdentitySnapshot) {
        guard ServerRegistry.shared.operationalMacs.isEmpty else { return }
        startMacLocalPairingPublisher { claim in
            Self.existingHouseClaim(claim, matchesHouseholdId: snapshot.id)
        }
    }

    @MainActor
    private func startMacLocalPairingPublisher(
        acceptingClaim: @escaping @Sendable (SetupInvitationDirectClaim) -> Bool
    ) {
        stopMacLocalPairingPublisher()
        let expiresAt = UInt64(max(0, Date().timeIntervalSince1970)) + 300
        let invitation = SetupInvitationPayload(
            token: SetupInvitationToken(),
            ownerDisplayName: nil,
            expiresAt: expiresAt,
            iphoneApnsToken: nil,
            iphoneDeviceID: PairedMacsStore.shared.deviceID,
            iphoneDeviceName: PairedMacsStore.shared.deviceName,
            iphoneDeviceModel: PairedMacsStore.shared.deviceModel
        )
        let publisher = SetupInvitationPublisher(invitation: invitation)
        publisher.onMacClaimed = { [weak publisher] claim in
            Task { @MainActor in
                guard acceptingClaim(claim), let pairing = claim.macLocalPairing else { return }
                installMacLocalPairing(pairing)
                publisher?.stop()
                if let publisher, macLocalPairingPublisher === publisher {
                    macLocalPairingPublisher = nil
                }
            }
        }
        macLocalPairingPublisher = publisher
        publisher.start()

        Task { [weak publisher] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            await MainActor.run {
                guard let publisher, macLocalPairingPublisher === publisher else { return }
                publisher.stop()
                macLocalPairingPublisher = nil
            }
        }
    }

    @MainActor
    private func stopMacLocalPairingPublisher() {
        macLocalPairingPublisher?.stop()
        macLocalPairingPublisher = nil
    }

    nonisolated private static func devicePairingClaim(
        _ claim: SetupInvitationDirectClaim,
        matches link: HouseholdDevicePairingLink
    ) -> Bool {
        guard let claimedLink = existingHousePairingLink(from: claim) else { return false }
        return claimedLink.householdId == link.householdId
            && claimedLink.pairingNonce == link.pairingNonce
    }

    nonisolated private static func existingHouseClaim(
        _ claim: SetupInvitationDirectClaim,
        matchesHouseholdId householdId: String
    ) -> Bool {
        existingHousePairingLink(from: claim)?.householdId == householdId
    }

    nonisolated private static func existingHousePairingLink(from claim: SetupInvitationDirectClaim) -> HouseholdDevicePairingLink? {
        guard let existingHouse = claim.existingHouse,
              let url = URL(string: existingHouse.pairDeviceURI) else {
            return nil
        }
        return try? HouseholdDevicePairingLink(url: url)
    }

    private func handleIncomingDeepLink(_ url: URL) {
        // On cold launch with a passcode-locked device, the keychain stays
        // encrypted until the user unlocks. The dispatcher reads
        // `activeHouseholdId` through `SoyehtIdentity`, whose state is
        // `.unavailable(.protectedDataUnavailable)` while the keychain is
        // locked. Without this gate a valid `pair-machine` URL would be
        // misclassified as `hhMismatch` because the existing session is not
        // yet decryptable. Defer the URL by leaving
        // `store.pendingDeepLink` set (intentionally NOT cleared here —
        // the `protectedDataDidBecomeAvailableNotification` observer in
        // `body` reads it back once iOS unlocks). Note that the upstream
        // `.onReceive(store.$pendingDeepLink.compactMap { $0 })` does NOT
        // re-fire on unlock because the published value did not change;
        // the new observer is the load-bearing replay trigger. Skipping
        // the `lastHandledDeepLink` update here keeps the replay from
        // being suppressed by the 1 s dedup window.
        if !UIApplication.shared.isProtectedDataAvailable {
            householdDeepLinkLogger.info(
                "deferring deep-link until protected data is available url=\(url.absoluteString, privacy: .sensitive)"
            )
            return
        }

        let key = url.absoluteString
        let now = Date()
        if key == lastHandledDeepLink, now.timeIntervalSince(lastHandledDeepLinkAt) < 1 {
            return
        }
        lastHandledDeepLink = key
        lastHandledDeepLinkAt = now

        // theyos://instance/<id> — emitted by the deploy Live Activity widgetURL.
        // Resolve the instance from the cached list and hand it off to
        // `autoSelectInstance`, which the InstanceListView consumes on appear
        // to open the session sheet. If we're not yet on the instance list
        // (e.g. cold launch from lock screen), flipping appState below is
        // enough — the list will pick up the autoSelect on first load.
        if url.scheme == "theyos", url.host == "instance" {
            let instanceId = url.lastPathComponent
            store.pendingDeepLink = nil
            guard !instanceId.isEmpty else { return }
            let alreadyOnList: Bool = {
                if case .instanceList = appState { return true } else { return false }
            }()
            // Search every paired server's cache — the widget URL carries
            // only the instance id, not the owning server.
            if let found = store.findCachedInstance(id: instanceId) {
                autoSelectInstance = found.instance
                autoSelectServerId = found.serverId
                autoSelectSessionName = nil
            }
            // If we're not on the list (cold launch / terminal / qr), flip to it.
            // The list will fetch fresh instances and consume autoSelectInstance
            // on appear. If the instance isn't in cache yet, the list lands
            // empty-handed but the user still gets a soft navigation.
            if !alreadyOnList {
                withAnimation { appState = .instanceList }
            }
            return
        }

        // Local Mac handoff URLs carry pair_token/pane_nonce instead of the
        // legacy `token` — QRScanResult would reject them. Route directly
        // to `handleQRScanned` with a stub result; it checks `sourceURL`
        // for local handoff first and short-circuits.
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.scheme == "theyos",
           components.host == "connect",
           components.queryItems?.contains(where: { $0.name == "local_handoff" && $0.value == "mac_local" }) == true {
            store.pendingDeepLink = nil
            Task { await handleQRScanned(result: .connect(token: "", host: ""), sourceURL: url) }
            return
        }

        // `soyeht://household/pair-device` (Phase 2 first-owner pair) and
        // `soyeht://household/pair-machine` (Phase 3 machine join) URLs come
        // through here when the user opens the QR via the iOS Camera app or
        // taps a household pairing link in another app. Both go through the
        // same dispatcher the in-app scanner uses, but the **deep-link
        // path requires an explicit user confirmation for `pair-device`
        // before any pairing actually fires** — registering `soyeht://`
        // system-wide means any installed app can `UIApplication.open`
        // this URL, and `PairDeviceQR` only validates that the QR is
        // well-formed (P-256 key shape, ttl in future). It does NOT pin to
        // an expected household, so without a confirmation gate an
        // attacker who delivers the URL would silently enroll the
        // iPhone as the founding owner of an attacker-controlled
        // household. The camera path is consensual by construction
        // (the user pointed their phone at the QR); the deep-link path
        // is not. Surface the BIP-39 fingerprint of the household
        // public key so the operator can verify it matches the one
        // shown on the Mac before tapping pair.
        if url.scheme == "soyeht", url.host == "household" {
            store.pendingDeepLink = nil
            // Refuse a second pair URL while a confirmation is already
            // waiting on the operator OR while a pair is in flight. The
            // dispatcher's session gate closes on PERSISTED state only,
            // so without this short-circuit two attacker URLs landing
            // within the in-flight pair window can both pass dispatch
            // and race into `HouseholdPairingService.pair`. Public log
            // describes the reason; URL stays `.private` because nonce
            // and `hh_pub` are sensitive on a triage timeline.
            if pendingPairDeviceConfirmation != nil || isPairing {
                householdDeepLinkLogger.info(
                    "dropping concurrent household URL: pendingConfirmation=\(self.pendingPairDeviceConfirmation != nil, privacy: .public) isPairing=\(self.isPairing, privacy: .public) url=\(url.absoluteString, privacy: .sensitive)"
                )
                return
            }
            let dispatch = QRScannerDispatcher.result(
                for: url,
                activeHouseholdId: activeHouseholdId,
                now: Date()
            )
            switch dispatch {
            case .success(let result):
                if case .householdPairDevice(let pairURL) = result {
                    presentPairDeviceConfirmation(for: pairURL)
                } else {
                    Task { await handleQRScanned(result: result, sourceURL: url) }
                }
            case .failure(let error):
                // Silent in the UI but loud in os_log — production triage
                // for "I scanned the QR and nothing happened" needs a
                // breadcrumb. URL is `.private` so the public log redacts
                // potentially sensitive query params (nonce, hh_pub).
                householdDeepLinkLogger.error(
                    "household deep-link rejected: error=\(String(describing: error), privacy: .public) url=\(url.absoluteString, privacy: .sensitive)"
                )
            }
            return
        }

        guard let result = QRScanResult.from(url: url) else { return }
        store.pendingDeepLink = nil
        Task { await handleQRScanned(result: result, sourceURL: url) }
    }

    private func restoreNavigationIfNeeded() {
        guard let resolved = NavigationState.resolve(
            state: store.loadNavigationState(),
            activeServerId: store.activeServerId
        ) else { return }
        guard let activeId = store.activeServerId else { return }
        let cached = store.loadInstances(serverId: activeId)
        if let instance = cached.first(where: { $0.id == resolved.instanceId }) {
            autoSelectInstance = instance
            autoSelectServerId = activeId
            autoSelectSessionName = resolved.sessionName
        }
    }

    // MARK: - Terminal Restore

    private func attemptTerminalRestore() async -> (wsUrl: String, instance: SoyehtInstance, sessionName: String, context: ServerContext)? {
        guard let resolved = NavigationState.resolve(
            state: store.loadNavigationState(),
            activeServerId: store.activeServerId
        ) else { return nil }
        guard let activeId = store.activeServerId,
              let context = store.context(for: activeId) else {
            return nil
        }

        let cached = store.loadInstances(serverId: activeId)
        guard let instance = cached.first(where: { $0.id == resolved.instanceId }),
              let sessionName = resolved.sessionName else {
            return nil
        }

        let wsUrl = apiClient.buildWebSocketURL(
            container: instance.container,
            sessionId: sessionName,
            context: context
        )

        guard let wsURL = URL(string: wsUrl) else { return nil }

        let result = await TerminalWebSocketHandshake.verify(url: wsURL, timeout: 5)
        switch result {
        case .success:
            return (wsUrl, instance, sessionName, context)
        case .failure:
            return nil
        }
    }

    // MARK: - Auth Flow

    private func seedDebugServerIfNeeded() {
        #if DEBUG
        let host = DebugBootstrapConfig.apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = DebugBootstrapConfig.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else { return }

        let expiresAt = DebugBootstrapConfig.expiresAt.isEmpty ? nil : DebugBootstrapConfig.expiresAt
        let server = PairedServer(
            id: UUID().uuidString,
            host: host,
            name: "debug",
            role: "admin",
            pairedAt: Date(),
            expiresAt: expiresAt
        )
        let stored = store.addServer(server, token: token)
        store.setActiveServer(id: stored.id)
        #endif
    }

    private func handlePostSplash() async {
        seedDebugServerIfNeeded()
        if let pendingURL = store.pendingDeepLink {
            await MainActor.run {
                handleIncomingDeepLink(pendingURL)
            }
            if store.pendingDeepLink == nil {
                return
            }
        }
        if OnboardingLaunchIntent.consumeQRScannerRequest() {
            await MainActor.run {
                PairedMacRegistry.shared.reconcileClients()
                withAnimation { appState = .qrScanner }
            }
            return
        }
        #if targetEnvironment(simulator)
        // Simulator shortcut: pre-configure as a paired server
        let simHost = DebugBootstrapConfig.apiHost
        let simToken = DebugBootstrapConfig.sessionToken
        if !simHost.isEmpty, !simToken.isEmpty {
            let server = PairedServer(
                id: UUID().uuidString,
                host: simHost,
                name: "simulator",
                role: "admin",
                pairedAt: Date(),
                expiresAt: DebugBootstrapConfig.expiresAt.isEmpty ? nil : DebugBootstrapConfig.expiresAt
            )
            let stored = store.addServer(server, token: simToken)
            store.setActiveServer(id: stored.id)
        }
        if let restored = await attemptTerminalRestore() {
            await MainActor.run {
                store.saveNavigationState(NavigationState(
                    serverId: restored.context.serverId,
                    instanceId: restored.instance.id,
                    sessionName: restored.sessionName,
                    savedAt: Date()
                ))
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState = .terminal(
                        wsUrl: restored.wsUrl,
                        restored.instance,
                        sessionName: restored.sessionName,
                        context: restored.context
                    )
                }
            }
        } else {
            await MainActor.run {
                restoreNavigationIfNeeded()
                withAnimation { appState = .instanceList }
            }
        }
        #else
        let serverContexts = await MainActor.run {
            ServerRegistry.shared.refreshFromLegacyStores()
            return ServerRegistry.shared.operationalServers.compactMap { server in
                store.context(for: server.id)
            }
        }

        if let identity = loadActiveIdentityForLifecycle(reason: "postSplash") {
            await MainActor.run {
                machineJoinRuntime.activate(identity.underlying)
            }
            // This best-effort authority bootstrap has no raw endpoint
            // reader in the UI. It may add an identity-only base-machine row,
            // but never a route or HMAC pairing adapter.
            await BaseMachineProjector.shared.refresh()
            if serverContexts.isEmpty {
                await MainActor.run {
                    if ServerRegistry.shared.operationalMacs.isEmpty {
                        withAnimation { appState = .householdHome(identity) }
                    } else {
                        PairedMacRegistry.shared.reconcileClients()
                        restoreNavigationIfNeeded()
                        withAnimation { appState = .instanceList }
                    }
                }
                return
            }
        }

        if serverContexts.isEmpty {
            await MainActor.run {
                PairedMacRegistry.shared.reconcileClients()
                withAnimation {
                    appState = ServerRegistry.shared.operationalMacs.isEmpty ? .qrScanner : .instanceList
                }
            }
            return
        }

        // Auto-select the active server or first available
        if let ctx = serverContexts.first(where: { $0.server.id == store.activeServerId }) ?? serverContexts.first {
            store.setActiveServer(id: ctx.server.id)
            let valid = (try? await apiClient.validateSession(context: ctx)) ?? false
            if valid {
                if let restored = await attemptTerminalRestore() {
                    await MainActor.run {
                        store.saveNavigationState(NavigationState(
                            serverId: restored.context.serverId,
                            instanceId: restored.instance.id,
                            sessionName: restored.sessionName,
                            savedAt: Date()
                        ))
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .terminal(
                                wsUrl: restored.wsUrl,
                                restored.instance,
                                sessionName: restored.sessionName,
                                context: restored.context
                            )
                        }
                    }
                } else {
                    await MainActor.run {
                        restoreNavigationIfNeeded()
                        withAnimation { appState = .instanceList }
                    }
                }
            } else {
                await MainActor.run {
                    store.clearNavigationState()
                    withAnimation { appState = .qrScanner }
                }
            }
        }
        #endif
    }

    @MainActor
    private func loadActiveIdentityForLifecycle(reason: String) -> SoyehtIdentitySnapshot? {
        let macCount = ServerRegistry.shared.macs.count
        identity.reload()
        let snapshot = identity.active
        householdLifecycleLogger.info(
            "soyeht_diag active_household_lookup reason=\(reason, privacy: .public) present=\(snapshot != nil, privacy: .public) mac_count=\(macCount, privacy: .public)"
        )
        if case .unavailable(.decodingFailed) = identity.state {
            householdLifecycleLogger.error(
                "soyeht_diag active_household_lookup_failed reason=\(reason, privacy: .public) error=decodingFailed mac_count=\(macCount, privacy: .public)"
            )
        }
        return snapshot
    }

    /// Opens a pane on a paired Mac via presence. Requests an attach nonce
    /// from the persistent WS, builds the pane attach URL and transitions the
    /// app to `.localTerminal`.
    private func attachToMacPane(macID: UUID, pane: PaneEntry) async -> Bool {
        guard let client = PairedMacRegistry.shared.client(for: macID),
              let mac = ServerRegistry.shared.pairedMac(for: macID.uuidString),
              mac.attachPort != nil else {
            await MainActor.run {
                errorMessage = String(localized: "ssh.error.macUnreachable", comment: "Shown when the paired Mac can't be reached — user should open Soyeht on Mac.")
            }
            return false
        }

        do {
            guard let host = client.currentAttachHost ?? mac.lastHost,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "SoyehtAttach", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "ssh.attach.error.unknownHost", comment: "Reconnect error — no lastHost stored for this paired Mac.")])
            }
            let grant = try await client.requestAttachGrant(paneID: pane.id)
            guard let wsURL = MacLocalWebSocketEndpoint.paneAttachURL(
                host: host,
                port: grant.port,
                paneID: grant.paneID,
                nonce: grant.nonce
            )?.absoluteString else {
                throw NSError(domain: "SoyehtAttach", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "ssh.attach.error.invalidURL", comment: "Reconnect error — the paired Mac attach URL could not be built.")])
            }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState = .localTerminal(wsUrl: wsURL, title: pane.title, macID: macID, paneID: pane.id)
                }
            }
            return true
        } catch {
            await MainActor.run {
                errorMessage = String(
                    localized: "ssh.error.attachPaneFailed",
                    defaultValue: "Failed to connect to pane: \(error.localizedDescription)",
                    comment: "Shown when requestAttachGrant fails. %@ = underlying error."
                )
            }
            return false
        }
    }

    /// Builds the reconnect-time URL refresher for a Fase 2 attach terminal.
    /// Returns nil (no refresher) when the state didn't carry macID/paneID
    /// (Fase 1 QR-based local handoff).
    ///
    /// On each call, waits briefly for the presence WS to re-authenticate,
    /// then asks the Mac for a fresh attach nonce and rebuilds the ws URL.
    @MainActor
    static func makeAttachRefresher(macID: UUID?, paneID: String?) -> (@MainActor () async throws -> String)? {
        guard let macID, let paneID else { return nil }
        return { @MainActor in
            // Wait up to 8s for presence to come back after a background cycle.
            let waitDeadline = Date().addingTimeInterval(8)
            while Date() < waitDeadline {
                if let client = PairedMacRegistry.shared.client(for: macID),
                   client.status == .authenticated {
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
            }
            guard let client = PairedMacRegistry.shared.client(for: macID) else {
                throw NSError(domain: "SoyehtAttach", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "ssh.attach.error.presenceUnavailable", comment: "Reconnect error — presence WS did not come back in time for this Mac.")])
            }
            let mac = ServerRegistry.shared.pairedMac(for: macID.uuidString)
            guard let host = client.currentAttachHost ?? mac?.lastHost else {
                throw NSError(domain: "SoyehtAttach", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "ssh.attach.error.unknownHost", comment: "Reconnect error — no lastHost stored for this paired Mac.")])
            }
            let grant = try await client.requestAttachGrant(paneID: paneID)
            guard let url = MacLocalWebSocketEndpoint.paneAttachURL(
                host: host,
                port: grant.port,
                paneID: grant.paneID,
                nonce: grant.nonce
            ) else {
                throw NSError(domain: "SoyehtAttach", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "ssh.attach.error.invalidURL", comment: "Reconnect error — the paired Mac attach URL could not be built.")])
            }
            return url.absoluteString
        }
    }

    @MainActor
    static func makeHouseholdAttachRequestRefresher(
        endpoint: URL,
        container: String,
        workspaceId: String
    ) -> (@MainActor () async throws -> URLRequest) {
        return { @MainActor in
            let token = try await SoyehtAPIClient.shared.mintHouseholdTerminalAttachToken(
                container: container,
                workspaceId: workspaceId,
                householdEndpoint: endpoint
            )
            return try SoyehtAPIClient.shared.makeHouseholdTerminalWebSocketRequest(
                endpoint: endpoint,
                container: container,
                workspaceId: workspaceId,
                attachToken: token.token
            )
        }
    }

    private func handleQRScanned(result: QRScanResult, sourceURL: URL? = nil) async {
        if let target = localHandoffTarget(from: sourceURL),
           let local = await resolveLocalHandoff(target: target) {
            await MainActor.run {
                rememberLocalHandoffMac(target, selectedWsUrl: local.wsUrl)
                withAnimation(.easeInOut(duration: 0.3)) {
                    // Fase 1 QR-based handoff — no refresher; reconnect would
                    // require re-scanning the QR anyway.
                    appState = .localTerminal(wsUrl: local.wsUrl, title: local.title, macID: nil, paneID: nil)
                }
            }
            return
        }

        switch result {
        case .householdPairDevice(let url):
            await handlePairDevice(url: url)

        case .householdDevicePairing(let url):
            await handleDevicePairing(url: url)

        case .householdPairMachine(let envelope):
            let snapshot = await MainActor.run { () -> SoyehtIdentitySnapshot? in
                identity.reload()
                return identity.active
            }
            guard let snapshot else {
                await MainActor.run { errorMessage = JoinRequestConfirmationViewModel.localizedMessage(for: .hhMismatch) }
                return
            }
            let household = snapshot.underlying
            do {
                try await machineJoinRuntime.stageScannedMachineJoin(envelope, household: household)
                await MainActor.run {
                    errorMessage = nil
                    machineJoinRuntime.activate(household)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appState = .householdHome(snapshot)
                    }
                }
            } catch let error as MachineJoinError {
                await MainActor.run {
                    errorMessage = JoinRequestConfirmationViewModel.localizedMessage(for: error)
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }

        case .clawShareInvite(let invite):
            await MainActor.run {
                errorMessage = nil
                successMessage = nil
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState = .relayStreamOpening(invite)
                }
            }

        case .pair(let token, let host):
            do {
                let server = try await apiClient.pairServer(token: token, host: host)
                await showSuccessAndNavigate(message: String(
                    localized: "ssh.success.connectedToServer",
                    defaultValue: "connected to \(server.name)",
                    comment: "Success message after pairing with a server. %@ = server name."
                ))
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }

        case .connect(let token, let host):
            do {
                let response = try await apiClient.auth(qrToken: token, host: host)
                let fallbackTarget = continueTargetHint(from: sourceURL)
                let targetInstanceId = response.targetInstanceId ?? fallbackTarget?.instanceId
                let targetWorkspaceId = response.targetWorkspaceId ?? fallbackTarget?.workspaceId

                // Newer backends return `target_*` directly. Older ones only
                // return a generic connect token; in that case the Mac embeds
                // `instance_id` + `workspace_id` in the deep link so we can
                // reconstruct the exact workspace client-side.
                if let targetInstanceId,
                   let workspaceId = targetWorkspaceId,
                   let instance = response.instances.first(where: { $0.id == targetInstanceId }),
                   let serverId = store.activeServerId,
                   let ctx = store.context(for: serverId) {
                    let wsUrl = response.targetWsUrl
                        ?? apiClient.buildWebSocketURL(
                            host: host,
                            container: instance.container,
                            sessionId: workspaceId,
                            token: response.sessionToken
                        )
                    await MainActor.run {
                        store.saveNavigationState(NavigationState(
                            serverId: serverId,
                            instanceId: targetInstanceId,
                            sessionName: workspaceId,
                            savedAt: Date()
                        ))
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .terminal(
                                wsUrl: wsUrl,
                                instance,
                                sessionName: workspaceId,
                                context: ctx
                            )
                        }
                    }
                    return
                }
                await showSuccessAndNavigate(message: String(localized: "ssh.success.connected"))
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }

        case .invite(let token, let host):
            do {
                let server = try await apiClient.redeemInvite(token: token, host: host)
                await showSuccessAndNavigate(message: String(
                    localized: "ssh.success.joinedServer",
                    defaultValue: "joined \(server.name)",
                    comment: "Success message after redeeming an invite. %@ = server name."
                ))
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func isHouseholdPairingScan(_ result: QRScanResult) -> Bool {
        switch result {
        case .householdPairDevice, .householdDevicePairing:
            return true
        case .connect, .pair, .invite, .householdPairMachine, .clawShareInvite:
            return false
        }
    }

    private func devicePairingMessage(for error: Error) -> String {
        switch error {
        case HouseholdDevicePairingError.approvalTimedOut:
            return String(localized: "The approval timed out. Tap Add iPhone on the Mac and try again.")
        case HouseholdDevicePairingError.approvalRejected:
            return String(localized: "The Mac rejected this approval. Try Add iPhone again.")
        case HouseholdDevicePairingError.networkUnavailable:
            return String(localized: "The Mac is unreachable. Keep both devices on the same LAN or Tailscale.")
        case HouseholdDevicePairingError.certInvalid:
            return String(localized: "The approval could not be verified.")
        case HouseholdDevicePairingError.biometryCanceled:
            return String(localized: "Approval was canceled.")
        default:
            return error.localizedDescription
        }
    }

    private func pairingMessage(for error: HouseholdPairingError) -> String {
        String(localized: String.LocalizationValue(error.localizationKey), bundle: SoyehtCoreResources.bundle)
    }

    private func continueTargetHint(from url: URL?) -> (instanceId: String, workspaceId: String)? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "theyos",
              components.host == "connect" else { return nil }

        let items = components.queryItems ?? []
        let instanceId = items.first(where: { $0.name == "instance_id" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceId = items.first(where: { $0.name == "workspace_id" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let instanceId, !instanceId.isEmpty,
              let workspaceId, !workspaceId.isEmpty else { return nil }
        return (instanceId, workspaceId)
    }

    private struct LocalHandoffTarget {
        let wsCandidates: [String]
        let title: String
        let macID: UUID?
        let macName: String?
        let lastHost: String?
        let presencePort: Int?
        let attachPort: Int?
    }

    private func resolveLocalHandoff(target: LocalHandoffTarget) async -> (wsUrl: String, title: String)? {
        var fallback: String?
        for candidate in target.wsCandidates {
            fallback = fallback ?? candidate
            guard let wsURL = URL(string: candidate) else { continue }
            let result = await TerminalWebSocketHandshake.verify(url: wsURL, timeout: 2.5)
            if case .success = result {
                return (candidate, target.title)
            }
        }

        guard let fallback else { return nil }
        return (fallback, target.title)
    }

    private func localHandoffTarget(from url: URL?) -> LocalHandoffTarget? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "theyos",
              components.host == "connect" else { return nil }

        let items = components.queryItems ?? []
        guard items.contains(where: { $0.name == "local_handoff" && $0.value == "mac_local" }) else {
            return nil
        }

        let wsCandidates = items
            .filter { $0.name == "ws_url" }
            .compactMap(\.value)
            .filter { !$0.isEmpty }
            .filter { candidate in
                // Reject any non-WebSocket scheme so a deep link cannot
                // route the attach into http://, file://, ssh://, etc.
                // The deep link is unauthenticated input — any URL we
                // accept here is one we will dial; the scheme must be
                // exactly `ws` or `wss`.
                guard let url = URL(string: candidate),
                      let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "ws" || scheme == "wss"
            }
        guard !wsCandidates.isEmpty else { return nil }

        let title = items.first(where: { $0.name == "title" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let macID = items
            .first(where: { $0.name == PairingQueryKey.macID })?
            .value
            .flatMap(UUID.init(uuidString:))
        let macName = items
            .first(where: { $0.name == PairingQueryKey.macName })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lastHost = items
            .first(where: { $0.name == "host" })?
            .value
            .flatMap(Self.hostPort(from:))
        let presencePort = items
            .first(where: { $0.name == PairingQueryKey.presencePort })?
            .value
            .flatMap(Int.init)
        let attachPort = items
            .first(where: { $0.name == PairingQueryKey.attachPort })?
            .value
            .flatMap(Int.init)
        return LocalHandoffTarget(
            wsCandidates: wsCandidates,
            title: title?.isEmpty == false ? title! : "Local Mac",
            macID: macID,
            macName: macName?.isEmpty == false ? macName : nil,
            lastHost: lastHost,
            presencePort: presencePort,
            attachPort: attachPort
        )
    }

    @MainActor
    private func rememberLocalHandoffMac(_ target: LocalHandoffTarget, selectedWsUrl: String) {
        guard let macID = target.macID else { return }
        let store = PairedMacsStore.shared
        let hasSecret = store.hasSecret(for: macID)
        let hasEndpoints = target.presencePort != nil || target.attachPort != nil
        guard hasSecret || hasEndpoints else { return }

        let host = target.lastHost ?? Self.hostPort(from: selectedWsUrl)
        ServerRegistry.shared.upsertMacPairing(
            macID: macID,
            name: target.macName ?? "Mac",
            host: host,
            presencePort: target.presencePort,
            attachPort: target.attachPort
        )
        PairedMacRegistry.shared.reconcileClients()
    }

    private static func hostPort(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed),
              let host = components.host else {
            return trimmed
        }
        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }

    private func showSuccessAndNavigate(message: String) async {
        await MainActor.run {
            withAnimation { successMessage = message }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await MainActor.run {
            withAnimation {
                successMessage = nil
                appState = .instanceList
            }
        }
    }
}

// MARK: - Connection Success Overlay

private struct ConnectionSuccessOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle")
                    .font(Typography.sansDisplayLight)
                    .foregroundColor(SoyehtTheme.accentGreen)

                Text(message)
                    .font(Typography.monoSectionMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
            }
        }
    }
}

// MARK: - Terminal Container View

private struct TerminalContainerView: View {
    private static let logger = Logger(subsystem: "com.soyeht.mobile", category: "terminal-state")

    let wsUrl: String
    let instance: SoyehtInstance
    let sessionName: String
    let context: ServerContext
    let onDisconnect: () -> Void
    let onConnectionLost: () -> Void

    @State private var showSettings = false
    @State private var showFileBrowser = false
    @State private var fileBrowserForceCommander = false

    private let store = SessionStore.shared

    var body: some View {
        VStack(spacing: 0) {
            TerminalNavBar(
                instance: instance,
                onBack: onDisconnect,
                onFiles: {
                    fileBrowserForceCommander = false
                    showFileBrowser = true
                },
                onSettings: { showSettings = true }
            )

            WebSocketTerminalRepresentable(
                wsUrl: wsUrl,
                container: instance.container,
                sessionName: sessionName,
                serverContext: context,
                onFileBrowserRequested: {
                    fileBrowserForceCommander = true
                    showFileBrowser = true
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtConnectionLost)) { _ in
            onConnectionLost()
        }
        .sheet(isPresented: $showSettings) {
            SettingsRootView()
        }
        .fullScreenCover(isPresented: $showFileBrowser) {
            SessionFileBrowserContainer(
                container: instance.container,
                session: sessionName,
                instanceName: instance.name,
                initialPath: nil,
                isCommander: true,
                forceCommanderAccess: fileBrowserForceCommander,
                serverContext: context
            )
        }
        .task {
            #if DEBUG
            await MainActor.run {
                consumeDebugAutoOpenFileBrowserIfNeeded()
            }
            #endif
        }
    }

    #if DEBUG
    private func consumeDebugAutoOpenFileBrowserIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "soyeht.debug.autoOpenFileBrowser"
        guard defaults.bool(forKey: key) else { return }
        defaults.set(false, forKey: key)
        fileBrowserForceCommander = false
        showFileBrowser = true
    }
    #endif
}

private struct LocalTerminalContainerView: View {
    let wsUrl: String
    let title: String
    let onDisconnect: () -> Void
    let onConnectionLost: () -> Void
    /// For Fase 2 attach URLs: rebuilds the URL with a fresh single-use
    /// attach nonce before each reconnect. nil for Fase 1 local-handoff flow.
    var attachURLRefresher: (@MainActor () async throws -> String)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onDisconnect) {
                    Image(systemName: "chevron.left")
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }

                Text(title)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)

                Spacer()

                Text(verbatim: "[mac local]")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            WebSocketTerminalRepresentable(wsUrl: wsUrl, attachURLRefresher: attachURLRefresher)
        }
        .background(SoyehtTheme.bgPrimary)
        .onReceive(NotificationCenter.default.publisher(for: .soyehtConnectionLost)) { _ in
            onConnectionLost()
        }
    }
}

private struct HouseholdTerminalContainerView: View {
    let request: URLRequest
    let instance: SoyehtInstance
    let sessionName: String
    let onDisconnect: () -> Void
    let onConnectionLost: () -> Void
    var attachRequestRefresher: (@MainActor () async throws -> URLRequest)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onDisconnect) {
                    Image(systemName: "chevron.left")
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name)
                        .font(Typography.monoBodyLargeMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(sessionName)
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            WebSocketTerminalRepresentable(
                request: request,
                attachRequestRefresher: attachRequestRefresher
            )
        }
        .background(SoyehtTheme.bgPrimary)
        .onReceive(NotificationCenter.default.publisher(for: .soyehtConnectionLost)) { _ in
            onConnectionLost()
        }
    }
}

struct RelayStreamOpeningView: View {
    let invite: ClawShareInvite
    let onOpened: (RelayStreamTerminalConfiguration) -> Void
    let onCancel: () -> Void

    private let controller: any RelayStreamInviteOpening
    @State private var didStart = false
    @State private var isOpening = false
    @State private var status = String(localized: "Ready to connect.")
    @State private var errorMessage: String?
    @State private var openGeneration = 0
    @State private var openTask: Task<Void, Never>?

    init(
        invite: ClawShareInvite,
        onOpened: @escaping (RelayStreamTerminalConfiguration) -> Void,
        onCancel: @escaping () -> Void,
        controller: any RelayStreamInviteOpening = RelayStreamOpenController()
    ) {
        self.invite = invite
        self.onOpened = onOpened
        self.onCancel = onCancel
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            if !didStart && !isOpening && errorMessage == nil {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(SoyehtTheme.textSecondary)

                Text(String(
                    localized: "Connect to \(invite.clawId)?",
                    comment: "Relay stream invite confirmation title. %@ = claw id."
                ))
                .font(Typography.monoBodyLargeMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
                .multilineTextAlignment(.center)

                Text(invite.ownerPersonId)
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                HStack(spacing: 12) {
                    Button(action: cancelAndExit) {
                        Text("Cancel")
                            .font(Typography.sansNav)
                    }
                    .buttonStyle(.bordered)

                    Button(action: confirmAndOpen) {
                        Text("Connect")
                            .font(Typography.sansNav)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if isOpening {
                ProgressView()
                    .tint(SoyehtTheme.textSecondary)

                Text(status)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)

                Button(action: cancelAndExit) {
                    Text("Cancel")
                        .font(Typography.sansNav)
                }
                .buttonStyle(.bordered)
            } else if let errorMessage {
                Text(status)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)

                Text(errorMessage)
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.accentRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                HStack(spacing: 12) {
                    Button(action: cancelAndExit) {
                        Text("Cancel")
                            .font(Typography.sansNav)
                    }
                    .buttonStyle(.bordered)

                    Button(action: retry) {
                        Text("Retry")
                            .font(Typography.sansNav)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SoyehtTheme.bgPrimary)
        .onDisappear {
            cancelOpenTask()
        }
    }

    @MainActor
    private func retry() {
        didStart = false
        errorMessage = nil
        status = String(localized: "Ready to connect.")
    }

    @MainActor
    private func confirmAndOpen() {
        startOpenIfNeeded()
    }

    @MainActor
    private func startOpenIfNeeded() {
        guard !didStart else { return }
        openTask?.cancel()
        openGeneration &+= 1
        let generation = openGeneration
        didStart = true
        isOpening = true
        status = String(localized: "Opening relay stream...")
        errorMessage = nil
        openTask = Task {
            await openOnce(generation: generation)
        }
    }

    @MainActor
    private func cancelAndExit() {
        cancelOpenTask()
        onCancel()
    }

    @MainActor
    private func cancelOpenTask() {
        openGeneration &+= 1
        openTask?.cancel()
        openTask = nil
        isOpening = false
    }

    @MainActor
    private func openOnce(generation: Int) async {
        do {
            let configuration = try await controller.open(invite: invite)
            guard !Task.isCancelled, generation == openGeneration else { return }
            isOpening = false
            openTask = nil
            onOpened(configuration)
        } catch is CancellationError {
            guard generation == openGeneration else { return }
            isOpening = false
            openTask = nil
        } catch {
            guard generation == openGeneration else { return }
            isOpening = false
            openTask = nil
            status = String(localized: "Could not open relay stream.")
            errorMessage = error.localizedDescription
        }
    }
}

private struct RelayStreamTerminalContainerView: View {
    let configuration: RelayStreamTerminalConfiguration
    let onDisconnect: () -> Void
    let onConnectionLost: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onDisconnect) {
                    Image(systemName: "chevron.left")
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }

                Text(configuration.title)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(verbatim: "[relay]")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            RelayStreamTerminalRepresentable(configuration: configuration)
        }
        .background(SoyehtTheme.bgPrimary)
        .onReceive(NotificationCenter.default.publisher(for: .soyehtConnectionLost)) { _ in
            onConnectionLost()
        }
    }
}

private struct RelayStreamTerminalRepresentable: UIViewControllerRepresentable {
    let configuration: RelayStreamTerminalConfiguration

    func makeUIViewController(context: Context) -> TerminalHostViewController {
        let controller = TerminalHostViewController()
        controller.updateRelayStream(configuration)
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalHostViewController, context: Context) {
        uiViewController.updateRelayStream(configuration)
    }
}

// MARK: - WebSocket Terminal Representable

private struct WebSocketTerminalRepresentable: UIViewControllerRepresentable {
    enum Connection {
        case url(String)
        case request(URLRequest)
    }

    let connection: Connection
    var container: String = ""
    var sessionName: String = ""
    var serverContext: ServerContext? = nil
    var onFileBrowserRequested: (() -> Void)? = nil
    /// Called by WebSocketTerminalView on reconnect for Fase 2 attach URLs
    /// to obtain a fresh single-use nonce — otherwise retries loop against
    /// `policyViolation`. Optional; leave nil for non-attach flows.
    var attachURLRefresher: (@MainActor () async throws -> String)? = nil
    var attachRequestRefresher: (@MainActor () async throws -> URLRequest)? = nil

    init(
        wsUrl: String,
        container: String = "",
        sessionName: String = "",
        serverContext: ServerContext? = nil,
        onFileBrowserRequested: (() -> Void)? = nil,
        attachURLRefresher: (@MainActor () async throws -> String)? = nil
    ) {
        self.connection = .url(wsUrl)
        self.container = container
        self.sessionName = sessionName
        self.serverContext = serverContext
        self.onFileBrowserRequested = onFileBrowserRequested
        self.attachURLRefresher = attachURLRefresher
    }

    init(
        request: URLRequest,
        attachRequestRefresher: (@MainActor () async throws -> URLRequest)? = nil
    ) {
        self.connection = .request(request)
        self.attachRequestRefresher = attachRequestRefresher
    }

    func makeUIViewController(context: Context) -> TerminalHostViewController {
        let controller = TerminalHostViewController()
        controller.onFileBrowserRequested = onFileBrowserRequested
        controller.attachURLRefresher = attachURLRefresher
        controller.attachRequestRefresher = attachRequestRefresher
        if !container.isEmpty, !sessionName.isEmpty, let ctx = serverContext {
            controller.updateAttachmentContext(container: container, session: sessionName, serverContext: ctx)
        }
        switch connection {
        case .url(let wsUrl):
            controller.updateWebSocket(wsUrl)
        case .request(let request):
            controller.updateWebSocketRequest(request)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalHostViewController, context: Context) {
        uiViewController.onFileBrowserRequested = onFileBrowserRequested
        uiViewController.attachURLRefresher = attachURLRefresher
        uiViewController.attachRequestRefresher = attachRequestRefresher
        if !container.isEmpty, !sessionName.isEmpty, let ctx = serverContext {
            uiViewController.updateAttachmentContext(container: container, session: sessionName, serverContext: ctx)
        }
        switch connection {
        case .url(let wsUrl):
            uiViewController.updateWebSocket(wsUrl)
        case .request(let request):
            uiViewController.updateWebSocketRequest(request)
        }
    }
}

// MARK: - Terminal Nav Bar

private struct TerminalNavBar: View {
    let instance: SoyehtInstance
    let onBack: () -> Void
    let onFiles: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(Typography.sansNav)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Text(instance.name)
                .font(Typography.monoBodyLargeMedium)
                .foregroundColor(SoyehtTheme.textPrimary)

            Circle()
                .fill(instance.isOnline ? SoyehtTheme.statusOnline : SoyehtTheme.statusOffline)
                .frame(width: 6, height: 6)

            Spacer()

            Text(instance.displayTag)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textSecondary)

            Button(action: onFiles) {
                Image(systemName: "folder")
                    .font(Typography.iconMedium)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(Typography.iconMedium)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(SoyehtTheme.bgSecondary)
    }
}

// MARK: - Legacy SSH Representable (kept for fallback)

struct TerminalHostRepresentable: UIViewControllerRepresentable {
    let connectionInfo: SSHConnectionInfo

    func makeUIViewController(context: Context) -> TerminalHostViewController {
        let controller = TerminalHostViewController()
        controller.updateConnectionInfo(connectionInfo)
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalHostViewController, context: Context) {
        uiViewController.updateConnectionInfo(connectionInfo)
    }
}

// MARK: - Pair-Device Deep-Link Confirmation Sheet

/// Shown when a `soyeht://household/pair-device` URL arrives via the OS
/// deep-link path (Camera scan, Messages, AirDrop, another app's
/// `UIApplication.open`). The sheet surfaces the BLAKE3 → BIP-39
/// fingerprint of the household public key so the operator can verify
/// the QR they (think they) scanned is the QR the Mac is showing —
/// before any pairing actually fires. The camera path inside the
/// in-app `QRScannerView` does not show this sheet because pointing
/// the phone at a QR is itself the consent gesture; the deep-link
/// path has no equivalent gesture, so the gate has to be explicit.
fileprivate struct PairDeviceConfirmationSheet: View {
    let fingerprintWords: [String]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private static let fingerprintColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                bodyText
                fingerprintSection
                Spacer(minLength: 8)
                actionRow
            }
            .padding(20)
        }
        // Force the operator to make an explicit decision via Cancel or
        // Pair — both wired to audit-log breadcrumbs in `onCancel` /
        // `onConfirm`. If you ever drop this and allow swipe-down to
        // dismiss, route the swipe through `onCancel` so the
        // `pair-device user cancelled` log still fires; otherwise a
        // dismiss-without-decision would leak a hole in the audit trail.
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "//")
                .font(Typography.monoSection)
                .foregroundColor(SoyehtTheme.accentGreen)
            Text(LocalizedStringResource(
                "household.pairDevice.confirm.title",
                defaultValue: "confirm pair",
                comment: "Title of the deep-link pair-device confirmation sheet."
            ))
            .font(Typography.monoSection)
            .foregroundColor(SoyehtTheme.textPrimary)
        }
    }

    private var bodyText: some View {
        Text(LocalizedStringResource(
            "household.pairDevice.confirm.body",
            defaultValue: "This link wants to enroll you as the founding owner of a new household. Verify the fingerprint below matches the one shown on the Mac that displayed the QR.",
            comment: "Body text of the deep-link pair-device confirmation sheet, explaining why the user should verify the fingerprint."
        ))
        .font(Typography.monoBody)
        .foregroundColor(SoyehtTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fingerprintSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "seal")
                    .font(Typography.monoSmallBold)
                    .foregroundColor(SoyehtTheme.accentInfo)
                    .accessibilityHidden(true)
                Text(LocalizedStringResource(
                    "household.pairDevice.confirm.fingerprintLabel",
                    defaultValue: "household fingerprint",
                    comment: "Section header above the BIP-39 word grid."
                ))
                .font(Typography.monoSectionLabel)
                .foregroundColor(SoyehtTheme.textComment)
            }
            LazyVGrid(columns: Self.fingerprintColumns, alignment: .leading, spacing: 8) {
                ForEach(Array(fingerprintWords.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 8) {
                        Text(verbatim: "\(index + 1)")
                            .font(Typography.monoMicroBold)
                            .foregroundColor(SoyehtTheme.textComment)
                            .frame(width: 16, alignment: .trailing)
                        Text(verbatim: word)
                            .font(Typography.monoCardBody)
                            .foregroundColor(SoyehtTheme.textPrimary)
                            // 1-based index to match the visible numbering
                            // in the grid AND the convention documented on
                            // `pairDeviceFingerprintWord(_:)`. `enumerated()`
                            // yields 0-based offsets; the `+ 1` happens here,
                            // not in the AccessibilityID helper, so a future
                            // refactor that calls the helper directly without
                            // adjustment will not silently shift identifiers.
                            .accessibilityIdentifier(AccessibilityID.Household.pairDeviceFingerprintWord(index + 1))
                    }
                }
            }
            // SECURITY-relevant: the fingerprint is the operator's only line
            // of defence on the deep-link path against a malicious URL. A
            // VoiceOver user must hear ALL six words so they can verify
            // them against what the Mac shows. The previous label
            // ("Household fingerprint, six words.") only announced the
            // header — `.combine` + an explicit `accessibilityLabel`
            // overrides children labels, so the actual word values were
            // silently dropped from the announcement. Now the label
            // interpolates the words inline so the entire fingerprint is
            // spoken on a single VoiceOver focus stop. Accessibility audit
            // 2026-05-08 P0.
            //
            // Accessibility follow-up: regression-pin this label with a
            // SwiftUI accessibility snapshot test. The single-string
            // contract is security-load-bearing; a future refactor that
            // accidentally re-introduces a parallel `accessibilityLabel`
            // (or restores the previous "Household fingerprint, six
            // words." literal) would silently defeat the gate for
            // VoiceOver users without breaking any existing test.
            // Deferred from PR #67 review O#3 because SwiftUI
            // accessibility-output snapshot infra is not yet wired
            // into the test target.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(LocalizedStringResource(
                "household.pairDevice.confirm.fingerprintA11yLabel",
                defaultValue: "Household fingerprint, six words: \(fingerprintWords.joined(separator: ", ")).",
                comment: "VoiceOver label that introduces the fingerprint and reads the six BIP-39 words inline so the operator can verify them. The interpolated value is six space-separated words pulled from the canonical wordlist."
            )))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                // Reuse the existing `.lower` variant of the Cancel
                // button so this site doesn't fork the catalog with a
                // parallel default for the same word.
                Text("common.button.cancel.lower")
                .font(Typography.monoCardBody)
                .foregroundColor(SoyehtTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                )
            }
            .accessibilityIdentifier(AccessibilityID.Household.pairDeviceConfirmCancel)

            Button(action: onConfirm) {
                Text(LocalizedStringResource(
                    "household.pairDevice.confirm.action",
                    defaultValue: "pair as owner",
                    comment: "Primary action on the deep-link pair-device confirmation sheet — fires the actual pair flow."
                ))
                .font(Typography.monoCardBody)
                .foregroundColor(SoyehtTheme.bgPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SoyehtTheme.accentGreen)
                )
            }
            .accessibilityIdentifier(AccessibilityID.Household.pairDeviceConfirmConfirm)
        }
    }
}
