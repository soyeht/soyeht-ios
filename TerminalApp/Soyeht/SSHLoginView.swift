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

/// Sheet payload for the deep-link `soyeht://household/pair-device`
/// confirmation gate. The reason this gate exists is captured at the
/// call site in `handleIncomingDeepLink`; this struct is just the
/// `Identifiable` glue so SwiftUI's `.sheet(item:)` can route it.
fileprivate struct PendingPairDeviceConfirmation: Identifiable {
    let id = UUID()
    let url: URL
    let fingerprintWords: [String]
}

/// Derive the BLAKE3 → BIP-39 fingerprint words from a
/// `soyeht://household/pair-device` URL.
///
/// SAFETY contract for the deep-link path: if this throws, the caller
/// MUST refuse to pair — the fingerprint is the operator's only line
/// of defence on a URL delivered by an untrusted sender (any installed
/// app can call `UIApplication.open` on a `soyeht://` URL once the
/// scheme is registered). Concretely, the function throws when:
/// 1. `PairDeviceQR(url:now:)` rejects the URL (would only happen if
///    the dispatcher contract upstream changes — currently the
///    dispatcher already validates before reaching here).
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
    let qr = try PairDeviceQR(url: url, now: now)
    let wordlist = try BIP39Wordlist()
    let fingerprint = try OperatorFingerprint.derive(
        machinePublicKey: qr.householdPublicKey,
        wordlist: wordlist
    )
    return fingerprint.words
}

// MARK: - App Root View

struct SoyehtAppView: View {
    enum AppState {
        case splash
        case qrScanner
        case householdHome(ActiveHouseholdState)
        case instanceList
        case terminal(wsUrl: String, SoyehtInstance, sessionName: String, context: ServerContext)
        /// Fase 2 attach flow carries `macID`/`paneID` so the terminal view
        /// can refresh the single-use attach nonce via `PairedMacRegistry`
        /// on reconnect. Fase 1 local-handoff QR leaves both nil.
        case localTerminal(wsUrl: String, title: String, macID: UUID?, paneID: String?)
    }

    @State private var appState: AppState = .splash
    @State private var autoSelectInstance: SoyehtInstance?
    @State private var autoSelectServerId: String?
    @State private var autoSelectSessionName: String?
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var lastHandledDeepLink = ""
    @State private var lastHandledDeepLinkAt = Date.distantPast
    @State private var themeRevision = 0
    @State private var showSettings = false
    /// Set when a `soyeht://household/pair-device` deep link arrives via
    /// `scene(_:openURLContexts:)` on a device that has no active
    /// household yet. Triggers the confirmation sheet — see
    /// `handleIncomingDeepLink` for why this gate exists.
    @State private var pendingPairDeviceConfirmation: PendingPairDeviceConfirmation?
    /// Mirrors the active pair-device flow regardless of source (deep link
    /// or in-app camera). Set true when the operator commits to a pair
    /// (camera scan accepted, or sheet "pair as owner" tapped) and reset
    /// when the pair completes — success or failure. Guards against a
    /// second pair URL racing into a parallel `HouseholdPairingService.pair`
    /// call before the first has written to `HouseholdSessionStore`. The
    /// dispatcher's `activeHouseholdId == nil` gate only sees PERSISTED
    /// state, so it cannot block in-flight overlap on its own.
    @State private var isPairing = false
    @StateObject private var machineJoinRuntime = HouseholdMachineJoinRuntime()

    private let store = SessionStore.shared
    private let apiClient = SoyehtAPIClient.shared
    private let householdSessionStore = HouseholdSessionStore()
    private var hasHomeContent: Bool {
        !store.pairedServers.isEmpty || !PairedMacsStore.shared.macs.isEmpty || ((try? householdSessionStore.load()) != nil)
    }
    // TODO(swiftui-perf-followup): `householdSessionStore.load()` reaches
    // into the keychain on every body re-eval, plus a second hit when
    // `.qrScanner` reads `activeHouseholdId:` as a parameter. Audit
    // flagged MEDIUM-impact ("not a guaranteed frame drop"). Caching
    // behind a `@State String?` would require pairing `.task { reload() }`
    // with explicit invalidation triggers on every write site (pair
    // success, leave household, deep-link confirm) — a staleness
    // footgun with worse blast radius than the current syscall. Defer
    // until a profiling session proves the keychain hit is on a hot
    // frame path.
    private var activeHouseholdId: String? {
        do {
            return try householdSessionStore.load()?.householdId
        } catch {
            return nil
        }
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
                QRScannerView(
                    showsCancel: hasHomeContent,
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
                        if case .householdPairDevice = result, isPairing {
                            householdDeepLinkLogger.info(
                                "dropping concurrent camera-path pair-device scan; pair already in flight url=\(url?.absoluteString ?? "<nil>", privacy: .sensitive)"
                            )
                            return
                        }
                        Task { await handleQRScanned(result: result, sourceURL: url) }
                    },
                    onCancel: {
                        if hasHomeContent {
                            withAnimation { appState = .instanceList }
                        }
                    }
                )
                .transition(.opacity)

            case .householdHome(let household):
                HouseholdHomeView(
                    household: household,
                    machineJoinRuntime: machineJoinRuntime,
                    onAdd: {
                        withAnimation { appState = .qrScanner }
                    },
                    onSettings: {
                        showSettings = true
                    }
                )
                .transition(.opacity)

            case .instanceList:
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
                    onAddInstance: {
                        withAnimation { appState = .qrScanner }
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
                        Task { await attachToMacPane(macID: macID, pane: pane) }
                    },
                    autoSelectInstance: $autoSelectInstance,
                    autoSelectServerId: $autoSelectServerId,
                    autoSelectSessionName: $autoSelectSessionName
                )
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

            case .localTerminal(let wsUrl, let title, let macID, let paneID):
                LocalTerminalContainerView(
                    wsUrl: wsUrl,
                    title: title,
                    onDisconnect: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = hasHomeContent ? .instanceList : .qrScanner
                        }
                    },
                    onConnectionLost: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = hasHomeContent ? .instanceList : .qrScanner
                        }
                    },
                    attachURLRefresher: Self.makeAttachRefresher(macID: macID, paneID: paneID)
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
        .onReceive(NotificationCenter.default.publisher(for: .soyehtColorThemeChanged)) { _ in
            themeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtDeepLink)) { notification in
            guard let url = notification.object as? URL else { return }
            handleIncomingDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
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
                    isPairing = true
                    householdDeepLinkLogger.info(
                        "pair-device user confirmed; firing pair flow url=\(url.absoluteString, privacy: .sensitive)"
                    )
                    Task {
                        await handleQRScanned(
                            result: .householdPairDevice(url: url),
                            sourceURL: url
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
    }

    // MARK: - Navigation Restoration

    private func presentPairDeviceConfirmation(for url: URL) {
        do {
            let words = try pairDeviceFingerprintWords(for: url, now: Date())
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

    private func handleIncomingDeepLink(_ url: URL) {
        // On cold launch with a passcode-locked device, the keychain stays
        // encrypted until the user unlocks. The dispatcher reads
        // `activeHouseholdId` synchronously from `HouseholdSessionStore`
        // (keychain-backed), so without this gate a valid `pair-machine`
        // URL would be misclassified as `hhMismatch` because the existing
        // session is not yet decryptable. Defer the URL by leaving
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

        let existing = store.pairedServers.first(where: { $0.host == host })
        let server = PairedServer(
            id: existing?.id ?? UUID().uuidString,
            host: host,
            name: existing?.name ?? "debug",
            role: existing?.role ?? "admin",
            pairedAt: existing?.pairedAt ?? Date(),
            expiresAt: DebugBootstrapConfig.expiresAt.isEmpty ? existing?.expiresAt : DebugBootstrapConfig.expiresAt
        )
        store.addServer(server, token: token)
        store.setActiveServer(id: server.id)
        #endif
    }

    private func handlePostSplash() async {
        seedDebugServerIfNeeded()
        #if targetEnvironment(simulator)
        // Simulator shortcut: pre-configure as a paired server
        let simHost = DebugBootstrapConfig.apiHost
        let simToken = DebugBootstrapConfig.sessionToken
        if !simHost.isEmpty, !simToken.isEmpty, !store.pairedServers.contains(where: { $0.host == simHost }) {
            let server = PairedServer(
                id: UUID().uuidString,
                host: simHost,
                name: "simulator",
                role: "admin",
                pairedAt: Date(),
                expiresAt: DebugBootstrapConfig.expiresAt
            )
            store.addServer(server, token: simToken)
            store.setActiveServer(id: server.id)
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
        if let household = try? householdSessionStore.load() {
            await MainActor.run {
                machineJoinRuntime.activate(household)
            }
            await MainActor.run {
                withAnimation { appState = .householdHome(household) }
            }
            return
        }

        let servers = store.pairedServers

        if servers.isEmpty {
            await MainActor.run {
                PairedMacRegistry.shared.reconcileClients()
                withAnimation { appState = PairedMacsStore.shared.macs.isEmpty ? .qrScanner : .instanceList }
            }
            return
        }

        // Auto-select the active server or first available
        if let active = store.activeServer ?? servers.first {
            store.setActiveServer(id: active.id)
            guard let ctx = store.context(for: active.id) else {
                await MainActor.run {
                    store.clearNavigationState()
                    withAnimation { appState = .qrScanner }
                }
                return
            }
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

    /// Opens a pane on a paired Mac via presence. Requests an attach nonce
    /// from the persistent WS, builds the pane attach URL and transitions the
    /// app to `.localTerminal`.
    private func attachToMacPane(macID: UUID, pane: PaneEntry) async {
        guard let client = PairedMacRegistry.shared.client(for: macID),
              let mac = PairedMacsStore.shared.macs.first(where: { $0.macID == macID }),
              let host = mac.lastHost,
              mac.attachPort != nil else {
            await MainActor.run {
                errorMessage = String(localized: "ssh.error.macUnreachable", comment: "Shown when the paired Mac can't be reached — user should open Soyeht on Mac.")
            }
            return
        }

        do {
            let grant = try await client.requestAttachGrant(paneID: pane.id)
            // Host may be "192.0.2.17" (no port) or "192.0.2.17:12345"
            // (legacy Fase 1 cache). Strip any trailing port before composing.
            let bareHost: String = {
                if let colon = host.lastIndex(of: ":"), !host.contains("::") {
                    return String(host[..<colon])
                }
                return host
            }()
            let scheme = SoyehtAPIClient.isLocalHost(bareHost) ? "ws" : "wss"
            let wsURL = "\(scheme)://\(bareHost):\(grant.port)/panes/\(grant.paneID)/attach?nonce=\(grant.nonce)"
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState = .localTerminal(wsUrl: wsURL, title: pane.title, macID: macID, paneID: pane.id)
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = String(
                    localized: "ssh.error.attachPaneFailed",
                    defaultValue: "Failed to connect to pane: \(error.localizedDescription)",
                    comment: "Shown when requestAttachGrant fails. %@ = underlying error."
                )
            }
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
            let mac = PairedMacsStore.shared.macs.first(where: { $0.macID == macID })
            guard let host = mac?.lastHost else {
                throw NSError(domain: "SoyehtAttach", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "ssh.attach.error.unknownHost", comment: "Reconnect error — no lastHost stored for this paired Mac.")])
            }
            let grant = try await client.requestAttachGrant(paneID: paneID)
            let bareHost: String = {
                if let colon = host.lastIndex(of: ":"), !host.contains("::") {
                    return String(host[..<colon])
                }
                return host
            }()
            let scheme = SoyehtAPIClient.isLocalHost(bareHost) ? "ws" : "wss"
            return "\(scheme)://\(bareHost):\(grant.port)/panes/\(grant.paneID)/attach?nonce=\(grant.nonce)"
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
            // Idempotent guard — the deep-link path already flips this in
            // the sheet's `onConfirm`, but the camera path enters here
            // directly. Either way, mirror the in-flight state so a
            // second pair URL arriving via either path is dropped at
            // `handleIncomingDeepLink` until this Task settles.
            await MainActor.run { isPairing = true }
            do {
                let household = try await HouseholdPairingService().pair(
                    url: url,
                    displayName: await MainActor.run { HouseholdOwnerDisplayName.defaultName() }
                )
                do {
                    _ = try await APNSRegistrationCoordinator.shared.handleSessionActivated()
                } catch {
                    householdAPNSLogger.error("APNS registration after household pairing failed: \(String(describing: error), privacy: .public)")
                }
                await MainActor.run {
                    isPairing = false
                    machineJoinRuntime.activate(household)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appState = .householdHome(household)
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

        case .householdPairMachine(let envelope):
            guard let household = try? householdSessionStore.load() else {
                await MainActor.run { errorMessage = JoinRequestConfirmationViewModel.localizedMessage(for: .hhMismatch) }
                return
            }
            do {
                try await machineJoinRuntime.stageScannedMachineJoin(envelope, household: household)
                await MainActor.run {
                    errorMessage = nil
                    machineJoinRuntime.activate(household)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appState = .householdHome(household)
                    }
                }
            } catch let error as MachineJoinError {
                await MainActor.run {
                    errorMessage = JoinRequestConfirmationViewModel.localizedMessage(for: error)
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }

        case .pair(let token, let host):
            do {
                let server = try await apiClient.pairServer(token: token, host: host)
                await showSuccessAndNavigate(message: "connected to \(server.name)")
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
                await showSuccessAndNavigate(message: "connected successfully")
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }

        case .invite(let token, let host):
            do {
                let server = try await apiClient.redeemInvite(token: token, host: host)
                await showSuccessAndNavigate(message: "joined \(server.name)")
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
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
        store.upsertMac(
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

// MARK: - WebSocket Terminal Representable

private struct WebSocketTerminalRepresentable: UIViewControllerRepresentable {
    let wsUrl: String
    var container: String = ""
    var sessionName: String = ""
    var serverContext: ServerContext? = nil
    var onFileBrowserRequested: (() -> Void)? = nil
    /// Called by WebSocketTerminalView on reconnect for Fase 2 attach URLs
    /// to obtain a fresh single-use nonce — otherwise retries loop against
    /// `policyViolation`. Optional; leave nil for non-attach flows.
    var attachURLRefresher: (@MainActor () async throws -> String)? = nil

    func makeUIViewController(context: Context) -> TerminalHostViewController {
        let controller = TerminalHostViewController()
        controller.onFileBrowserRequested = onFileBrowserRequested
        controller.attachURLRefresher = attachURLRefresher
        if !container.isEmpty, !sessionName.isEmpty, let ctx = serverContext {
            controller.updateAttachmentContext(container: container, session: sessionName, serverContext: ctx)
        }
        controller.updateWebSocket(wsUrl)
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalHostViewController, context: Context) {
        uiViewController.onFileBrowserRequested = onFileBrowserRequested
        uiViewController.attachURLRefresher = attachURLRefresher
        if !container.isEmpty, !sessionName.isEmpty, let ctx = serverContext {
            uiViewController.updateAttachmentContext(container: container, session: sessionName, serverContext: ctx)
        }
        uiViewController.updateWebSocket(wsUrl)
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(LocalizedStringResource(
                "household.pairDevice.confirm.fingerprintA11yLabel",
                defaultValue: "Household fingerprint, six words.",
                comment: "VoiceOver label that introduces the fingerprint grid before the words are announced."
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
