import SwiftUI
import SoyehtCore
import SwiftTerm
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

// MARK: - App Root View

struct SoyehtAppView: View {
    enum AppState {
        case splash
        case qrScanner
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

    private let store = SessionStore.shared
    private let apiClient = SoyehtAPIClient.shared

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
                    onScanned: { result, url in
                        Task { await handleQRScanned(result: result, sourceURL: url) }
                    },
                    onCancel: {
                        if !store.pairedServers.isEmpty {
                            withAnimation { appState = .instanceList }
                        }
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
                            appState = store.pairedServers.isEmpty ? .qrScanner : .instanceList
                        }
                    },
                    onConnectionLost: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = store.pairedServers.isEmpty ? .qrScanner : .instanceList
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
        .preferredColorScheme(.dark)
        .onReceive(store.$pendingDeepLink.compactMap { $0 }) { url in
            handleIncomingDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtDeepLink)) { notification in
            guard let url = notification.object as? URL else { return }
            handleIncomingDeepLink(url)
        }
        .alert("error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Navigation Restoration

    private func handleIncomingDeepLink(_ url: URL) {
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

        let result = await WebSocketTerminalView.verifyHandshake(url: wsURL, timeout: 5)
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
        let servers = store.pairedServers

        if servers.isEmpty {
            await MainActor.run {
                withAnimation { appState = .qrScanner }
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
              let attachPort = mac.attachPort else {
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
            let wsURL = "ws://\(bareHost):\(grant.port)/panes/\(grant.paneID)/attach?nonce=\(grant.nonce)"
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
            return "ws://\(bareHost):\(grant.port)/panes/\(grant.paneID)/attach?nonce=\(grant.nonce)"
        }
    }

    private func handleQRScanned(result: QRScanResult, sourceURL: URL? = nil) async {
        if let local = await resolveLocalHandoff(from: sourceURL) {
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    // Fase 1 QR-based handoff — no refresher; reconnect would
                    // require re-scanning the QR anyway.
                    appState = .localTerminal(wsUrl: local.wsUrl, title: local.title, macID: nil, paneID: nil)
                }
            }
            return
        }

        switch result {
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

    private func resolveLocalHandoff(from url: URL?) async -> (wsUrl: String, title: String)? {
        guard let target = localHandoffTarget(from: url) else { return nil }

        var fallback: String?
        for candidate in target.wsCandidates {
            fallback = fallback ?? candidate
            guard let wsURL = URL(string: candidate) else { continue }
            let result = await WebSocketTerminalView.verifyHandshake(url: wsURL, timeout: 2.5)
            if case .success = result {
                return (candidate, target.title)
            }
        }

        guard let fallback else { return nil }
        return (fallback, target.title)
    }

    private func localHandoffTarget(from url: URL?) -> (wsCandidates: [String], title: String)? {
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
        guard !wsCandidates.isEmpty else { return nil }

        let title = items.first(where: { $0.name == "title" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (wsCandidates, (title?.isEmpty == false ? title! : "Local Mac"))
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
            SoyehtTheme.bgPrimary.opacity(0.95).ignoresSafeArea()

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
