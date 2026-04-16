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
                    onScanned: { result in
                        Task { await handleQRScanned(result: result) }
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

        guard let result = QRScanResult.from(url: url) else { return }
        store.pendingDeepLink = nil
        Task { await handleQRScanned(result: result) }
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

    private func handleQRScanned(result: QRScanResult) async {
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
                // "Continue on iPhone" handoff: backend prebuilds a ws_url for a
                // specific tmux workspace — jump straight into the terminal
                // instead of bouncing through the instance picker.
                if let targetInstanceId = response.targetInstanceId,
                   let wsUrl = response.targetWsUrl,
                   let workspaceId = response.targetWorkspaceId,
                   let instance = response.instances.first(where: { $0.id == targetInstanceId }),
                   let serverId = store.activeServerId,
                   let ctx = store.context(for: serverId) {
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

// MARK: - Commander / Mirror Mode

private enum DeviceMode {
    case commander   // PTY connected, real terminal
    case mirror      // Placeholder UI, no WS
}

private struct CommanderPlaceholderView: View {
    let commanderType: String
    let onTakeCommand: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if commanderType == "loading" {
                ProgressView()
                    .tint(SoyehtTheme.accentGreen)
                    .scaleEffect(1.2)
                Text("connecting...")
                    .font(Typography.monoBody)
                    .foregroundColor(SoyehtTheme.textSecondary)
            } else {
                Image(systemName: commanderType == "web" ? "desktopcomputer" : "iphone")
                    .font(Typography.sansDisplay)
                    .foregroundColor(SoyehtTheme.textSecondary)
                Text("Session controlled from \(commanderType == "web" ? "desktop" : "another device")")
                    .font(Typography.monoBodyLarge)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button(action: onTakeCommand) {
                    Text("Take Command")
                        .font(Typography.monoBodyLargeSemi)
                        .foregroundColor(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(SoyehtTheme.accentGreen)
                        .cornerRadius(8)
                }
                .accessibilityIdentifier(AccessibilityID.WebSocket.takeCommandButton)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SoyehtTheme.bgPrimary)
        .accessibilityIdentifier(AccessibilityID.WebSocket.mirrorModeIndicator)
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

    @State private var tmuxScrollState: TmuxScrollState = .none
    @State private var activePaneIndex: Int = 0
    @State private var activeWindowIndex: Int = 0
    @State private var tmuxPanes: [TmuxPane] = []
    @State private var fetchTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showFileBrowser = false
    @State private var fileBrowserCommanderState = false
    @State private var fileBrowserForceCommander = false
    @State private var deviceMode: DeviceMode = .mirror  // start neutral — no WS until sessionInfo resolves
    @State private var commanderType: String = "loading"
    @State private var paneGeneration: Int = 0

    private let store = SessionStore.shared

    enum TmuxScrollState: Equatable {
        case none
        case loading
        case active(content: String)
        case error(message: String)
        case unavailable

        static func == (lhs: TmuxScrollState, rhs: TmuxScrollState) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.loading, .loading), (.unavailable, .unavailable):
                return true
            case (.active(let a), .active(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var body: some View {
        let exitHistory = {
            fetchTask?.cancel()
            withAnimation { tmuxScrollState = .none }
            NotificationCenter.default.post(name: .soyehtTerminalResumeLive, object: nil)
        }

        VStack(spacing: 0) {
            TerminalNavBar(
                instance: instance,
                onBack: onDisconnect,
                onFiles: {
                    fileBrowserForceCommander = false
                    fileBrowserCommanderState = (deviceMode == .commander)
                    showFileBrowser = true
                },
                onSettings: { showSettings = true }
            )
            TmuxTabBar(
                tabs: tmuxPanes.map { pane in
                    let prefs = TerminalPreferences.shared
                    if let nick = prefs.paneNickname(
                        container: instance.container,
                        session: sessionName,
                        window: activeWindowIndex,
                        paneId: pane.paneId
                    ) {
                        return nick
                    }
                    return "\(pane.index):\(pane.command)"
                },
                activeIndex: $activePaneIndex,
                onTabSelected: { index in
                    paneGeneration += 1
                    let gen = paneGeneration
                    Task {
                        let success = await switchToPane(index)
                        guard gen == paneGeneration, success else { return }
                        activePaneIndex = index
                        NotificationCenter.default.post(
                            name: .soyehtActivePaneDidChange,
                            object: nil,
                            userInfo: [
                                SoyehtNotificationKey.container: instance.container,
                                SoyehtNotificationKey.session: sessionName
                            ]
                        )
                        if isHistoryOpen { fetchHistoryForActivePane() }
                    }
                }
            )

            ZStack {
                switch deviceMode {
                case .commander:
                    WebSocketTerminalRepresentable(
                        wsUrl: wsUrl,
                        container: instance.container,
                        sessionName: sessionName,
                        serverContext: context,
                        onCommanderChanged: {
                            Self.logger.info(
                                "[terminal] Commander changed for \(instance.container, privacy: .public)::\(sessionName, privacy: .public); switching to mirror"
                            )
                            deviceMode = .mirror
                            commanderType = "web"
                        },
                        onFileBrowserRequested: {
                            fileBrowserForceCommander = true
                            fileBrowserCommanderState = true
                            showFileBrowser = true
                        }
                    )
                case .mirror:
                    CommanderPlaceholderView(
                        commanderType: commanderType,
                        onTakeCommand: {
                            store.markLocalCommander(container: instance.container, session: sessionName)
                            Self.logger.info(
                                "[terminal] Take Command tapped for \(instance.container, privacy: .public)::\(sessionName, privacy: .public)"
                            )
                            deviceMode = .commander
                            // Zoom active pane so mobile shows one pane at a time
                            Task { await zoomActivePaneIfNeeded() }
                        }
                    )
                }

                switch tmuxScrollState {
                case .loading:
                    TmuxLoadingOverlay().transition(.opacity)
                case .active(let content):
                    TmuxHistoryView(content: content, paneName: activePaneName, onExit: exitHistory).transition(.opacity)
                case .error(let message):
                    TmuxErrorOverlay(message: message, onDismiss: exitHistory)
                        .transition(.move(edge: .top).combined(with: .opacity))
                case .unavailable:
                    TmuxUnavailableOverlay().transition(.move(edge: .top).combined(with: .opacity))
                case .none:
                    EmptyView()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtScrollTmuxTapped)) { _ in
            fetchHistoryForActivePane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtConnectionLost)) { _ in
            onConnectionLost()
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtSwipePaneNext)) { _ in
            let next = min(activePaneIndex + 1, tmuxPanes.count - 1)
            if next != activePaneIndex {
                paneGeneration += 1
                let gen = paneGeneration
                Task {
                    let success = await switchToPane(next)
                    guard gen == paneGeneration, success else { return }
                    activePaneIndex = next
                    NotificationCenter.default.post(
                        name: .soyehtActivePaneDidChange,
                        object: nil,
                        userInfo: [
                            SoyehtNotificationKey.container: instance.container,
                            SoyehtNotificationKey.session: sessionName
                        ]
                    )
                    if isHistoryOpen { fetchHistoryForActivePane() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtSwipePanePrev)) { _ in
            let prev = max(activePaneIndex - 1, 0)
            if prev != activePaneIndex {
                paneGeneration += 1
                let gen = paneGeneration
                Task {
                    let success = await switchToPane(prev)
                    guard gen == paneGeneration, success else { return }
                    activePaneIndex = prev
                    NotificationCenter.default.post(
                        name: .soyehtActivePaneDidChange,
                        object: nil,
                        userInfo: [
                            SoyehtNotificationKey.container: instance.container,
                            SoyehtNotificationKey.session: sessionName
                        ]
                    )
                    if isHistoryOpen { fetchHistoryForActivePane() }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsRootView()
        }
        .fullScreenCover(isPresented: $showFileBrowser) {
            SessionFileBrowserContainer(
                container: instance.container,
                session: sessionName,
                instanceName: instance.name,
                windowIndex: activeWindowIndex,
                initialPath: nil,
                isCommander: fileBrowserCommanderState,
                forceCommanderAccess: fileBrowserForceCommander,
                serverContext: context
            )
        }
        .task {
            do {
                let windows = try await SoyehtAPIClient.shared.listWindows(
                    container: instance.container,
                    session: sessionName,
                    context: context
                )
                let activeWindow = windows.first(where: { $0.active }) ?? windows.first
                activeWindowIndex = activeWindow?.index ?? 0

                tmuxPanes = try await SoyehtAPIClient.shared.listPanes(
                    container: instance.container,
                    session: sessionName,
                    windowIndex: activeWindowIndex,
                    context: context
                )
                if let idx = tmuxPanes.firstIndex(where: { $0.active }) {
                    activePaneIndex = idx
                }

                // Check if another device already has command
                do {
                    let hadLocalCommanderClaim = store.hasLocalCommanderClaim(
                        container: instance.container,
                        session: sessionName
                    )
                    let info = try await SoyehtAPIClient.shared.sessionInfo(
                        container: instance.container,
                        session: sessionName,
                        context: context
                    )
                    if let commander = info.commander {
                        if commander.clientType == "mobile" && hadLocalCommanderClaim {
                            Self.logger.info(
                                "[terminal] Restoring local mobile commander for \(instance.container, privacy: .public)::\(sessionName, privacy: .public)"
                            )
                            deviceMode = .commander
                            commanderType = commander.clientType
                            await zoomActivePaneIfNeeded()
                        } else {
                            store.clearLocalCommander(container: instance.container, session: sessionName)
                            Self.logger.info(
                                "[terminal] Entering mirror mode for \(instance.container, privacy: .public)::\(sessionName, privacy: .public); commander=\(commander.clientType, privacy: .public)"
                            )
                            deviceMode = .mirror
                            commanderType = commander.clientType
                        }
                    } else {
                        store.markLocalCommander(container: instance.container, session: sessionName)
                        Self.logger.info(
                            "[terminal] No active commander for \(instance.container, privacy: .public)::\(sessionName, privacy: .public); claiming locally"
                        )
                        deviceMode = .commander
                        await zoomActivePaneIfNeeded()
                    }
                } catch {
                    // sessionInfo request failed — default to commander so the
                    // user isn't stuck. This can happen on transient network
                    // errors; the WebSocket connection will reconcile the actual
                    // commander state once established.
                    store.markLocalCommander(container: instance.container, session: sessionName)
                    Self.logger.warning(
                        "[terminal] sessionInfo failed for \(instance.container, privacy: .public)::\(sessionName, privacy: .public) (\(error.localizedDescription, privacy: .public)); defaulting to commander"
                    )
                    deviceMode = .commander
                    await zoomActivePaneIfNeeded()
                }

                #if DEBUG
                await MainActor.run {
                    consumeDebugAutoOpenFileBrowserIfNeeded()
                }
                #endif
            } catch {
                tmuxPanes = []
                // Don't assume commander on network error — stay neutral (loading state)
                commanderType = "error"
            }
        }
    }

    private var isHistoryOpen: Bool {
        switch tmuxScrollState {
        case .active, .loading: return true
        default: return false
        }
    }

    private var activePaneName: String {
        guard activePaneIndex >= 0, activePaneIndex < tmuxPanes.count else { return "pane" }
        let pane = tmuxPanes[activePaneIndex]
        if let nick = TerminalPreferences.shared.paneNickname(
            container: instance.container,
            session: sessionName,
            window: activeWindowIndex,
            paneId: pane.paneId
        ) { return nick }
        return "\(pane.index):\(pane.command)"
    }

    private func switchToPane(_ index: Int) async -> Bool {
        guard index >= 0, index < tmuxPanes.count else { return false }
        let pane = tmuxPanes[index]
        do {
            try await SoyehtAPIClient.shared.selectPane(
                container: instance.container,
                session: sessionName,
                windowIndex: activeWindowIndex,
                paneIndex: pane.index,
                context: context
            )
            return true
        } catch {
            return false
        }
    }

    private func fetchHistoryForActivePane() {
        withAnimation { tmuxScrollState = .loading }
        fetchTask?.cancel()
        fetchTask = Task {
            do {
                let content = try await SoyehtAPIClient.shared.capturePaneContent(
                    container: instance.container,
                    session: sessionName,
                    context: context
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation { tmuxScrollState = .active(content: content) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation { tmuxScrollState = .error(message: error.localizedDescription) }
                }
            }
        }
    }

    private func zoomActivePaneIfNeeded() async {
        guard tmuxPanes.count > 1,
              let activePane = tmuxPanes.first(where: { $0.active }) else { return }
        try? await SoyehtAPIClient.shared.selectPane(
            container: instance.container,
            session: sessionName,
            windowIndex: activeWindowIndex,
            paneIndex: activePane.index,
            context: context
        )
    }

    #if DEBUG
    private func consumeDebugAutoOpenFileBrowserIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "soyeht.debug.autoOpenFileBrowser"
        guard defaults.bool(forKey: key), deviceMode == .commander else { return }
        defaults.set(false, forKey: key)
        fileBrowserForceCommander = false
        fileBrowserCommanderState = true
        showFileBrowser = true
    }
    #endif
}

// MARK: - WebSocket Terminal Representable

private struct WebSocketTerminalRepresentable: UIViewControllerRepresentable {
    let wsUrl: String
    var container: String = ""
    var sessionName: String = ""
    var serverContext: ServerContext? = nil
    var onCommanderChanged: (() -> Void)? = nil
    var onFileBrowserRequested: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> TerminalHostViewController {
        let controller = TerminalHostViewController()
        controller.onCommanderChanged = onCommanderChanged
        controller.onFileBrowserRequested = onFileBrowserRequested
        if !container.isEmpty, !sessionName.isEmpty, let ctx = serverContext {
            controller.updateAttachmentContext(container: container, session: sessionName, serverContext: ctx)
            controller.updateScrollbackContext(container: container, session: sessionName, serverContext: ctx)
        }
        controller.updateWebSocket(wsUrl)
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalHostViewController, context: Context) {
        uiViewController.onCommanderChanged = onCommanderChanged
        uiViewController.onFileBrowserRequested = onFileBrowserRequested
        if !container.isEmpty, !sessionName.isEmpty, let ctx = serverContext {
            uiViewController.updateAttachmentContext(container: container, session: sessionName, serverContext: ctx)
            uiViewController.updateScrollbackContext(container: container, session: sessionName, serverContext: ctx)
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
                    .font(Typography.sans(size: 15 * Typography.uiScale))
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(Typography.sans(size: 15 * Typography.uiScale))
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(SoyehtTheme.bgSecondary)
    }
}

// MARK: - Tmux Tab Bar

private struct TmuxTabBar: View {
    let tabs: [String]
    @Binding var activeIndex: Int
    var onTabSelected: ((Int) -> Void)? = nil

    var body: some View {
        if !tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button(action: {
                            onTabSelected?(index)
                        }) {
                            HStack(spacing: 6) {
                                if index == activeIndex {
                                    Circle()
                                        .fill(SoyehtTheme.accentGreen)
                                        .frame(width: 6, height: 6)
                                }
                                Text(tab)
                                    .font(Typography.monoLabel)
                                    .foregroundColor(index == activeIndex ? SoyehtTheme.textPrimary : SoyehtTheme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.TmuxTabBar.tab(index))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(SoyehtTheme.bgTertiary)
            .accessibilityIdentifier(AccessibilityID.TmuxTabBar.container)
        }
    }
}

// MARK: - Mode Indicator

// MARK: - Tmux Loading Overlay

private struct TmuxLoadingOverlay: View {
    var body: some View {
        ZStack {
            SoyehtTheme.overlayBg
            VStack(spacing: 16) {
                ProgressView()
                    .tint(SoyehtTheme.accentGreen)
                    .scaleEffect(1.2)
                Text("capturing history...")
                    .font(Typography.monoSectionSemi)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text("tmux capture-pane")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
        }
    }
}

// MARK: - Tmux History View (capture-pane viewer with multiple modes)

private struct TmuxHistoryView: View {
    let content: String
    let paneName: String
    let onExit: () -> Void

    @State private var viewMode: HistoryViewMode = .pager
    @State private var fontSize: CGFloat = TerminalPreferences.shared.fontSize
    @State private var themeVersion = 0

    enum HistoryViewMode: String, CaseIterable {
        case pan, pager
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content based on mode
            switch viewMode {
            case .pan:
                ScrollHistoryContent(content: content, fontSize: fontSize)
                    .id(themeVersion)
            case .pager:
                TerminalHistoryContent(content: content, fontSize: fontSize)
                    .id(themeVersion)
            }

            // Controls bar (bottom, thumb-reachable)
            HStack(spacing: 8) {
                // Pane indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(SoyehtTheme.historyGreen)
                        .frame(width: 5, height: 5)
                    Text(paneName)
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .lineLimit(1)
                }

                // Mode toggle
                HStack(spacing: 2) {
                    ForEach(HistoryViewMode.allCases, id: \.self) { mode in
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode } }) {
                            Text(mode.rawValue)
                                .font(Typography.mono(size: 14 * Typography.uiScale, weight: viewMode == mode ? .medium : .regular))
                                .foregroundColor(viewMode == mode ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 6)
                                .background(
                                    Rectangle().fill(
                                        viewMode == mode ? SoyehtTheme.historyGreenBg : Color.clear
                                    )
                                )
                                .overlay(
                                    Rectangle()
                                        .stroke(viewMode == mode ? SoyehtTheme.historyGreen : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(SoyehtTheme.historyToggleBg)

                Spacer()

                // Exit button
                Button(action: {
                    let haptic = UIImpactFeedbackGenerator(style: .light)
                    haptic.impactOccurred()
                    UIDevice.current.playInputClick()
                    onExit()
                }) {
                    Text("✕ exit")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(SoyehtTheme.historyGreenBadge)
                        .overlay(
                            RoundedRectangle(cornerRadius: 0)
                                .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(SoyehtTheme.historyControlsBg)

            // Hint bar
            HStack {
                Spacer()
                Text("↕ \(paneName) · drag to navigate")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.historyGray)
                Spacer()
            }
            .frame(height: 32)
            .background(SoyehtTheme.historyHintBg)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtFontSizeChanged)) { _ in
            fontSize = TerminalPreferences.shared.fontSize
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtColorThemeChanged)) { _ in
            themeVersion += 1
        }
    }
}

// MARK: - Mode: Scroll (ANSI colored, 2D scroll, no wrap)

private struct ScrollHistoryContent: View {
    let content: String
    let fontSize: CGFloat

    private var lines: [String] { content.components(separatedBy: "\n") }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(ANSIParser.parse(line.isEmpty ? " " : line, fontSize: fontSize))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                }
            }
        }
        .background(Color(hex: ColorTheme.active.backgroundHex))
    }
}

// MARK: - Read-Only TerminalView (no keyboard)

private class ReadOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
    override var canBecomeFocused: Bool { false }
}

// MARK: - Mode: Terminal (SwiftTerm TerminalView, native ANSI rendering)

private struct TerminalHistoryContent: UIViewRepresentable {
    let content: String
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            guard let tv = gesture.view as? ReadOnlyTerminalView,
                  !tv.hasActiveSelection else { return }
            HapticEngine.shared.play(for: "paneSwipe")
            let name: Notification.Name = gesture.direction == .left
                ? .soyehtSwipePaneNext : .soyehtSwipePanePrev
            NotificationCenter.default.post(name: name, object: nil)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UISwipeGestureRecognizer
        }
    }

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        let tv = ReadOnlyTerminalView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        SoyehtTerminalAppearance.apply(to: tv)
        tv.font = Typography.monoUIFont(size: fontSize, weight: .regular)

        let terminal = tv.getTerminal()
        terminal.changeScrollback(50000)

        let normalized = content.replacingOccurrences(of: "\n", with: "\r\n")
        tv.feed(byteArray: Array(normalized.utf8)[...])

        // Horizontal swipe to switch panes (pager mode: vertical scroll only)
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipeLeft.direction = .left
        swipeLeft.delegate = context.coordinator
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipeRight.direction = .right
        swipeRight.delegate = context.coordinator
        tv.addGestureRecognizer(swipeLeft)
        tv.addGestureRecognizer(swipeRight)

        return tv
    }

    func updateUIView(_ uiView: ReadOnlyTerminalView, context: Context) {
        uiView.font = Typography.monoUIFont(size: fontSize, weight: .regular)
        SoyehtTerminalAppearance.apply(to: uiView)
    }
}


// MARK: - Tmux Error Overlay

private struct TmuxErrorOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Text("[!]")
                    .font(Typography.monoLabelBold)
                    .foregroundColor(SoyehtTheme.textWarning)
                Text("capture-pane: \(message)")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textWarning)
                    .lineLimit(2)
                Spacer()
                Button("dismiss") { onDismiss() }
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(SoyehtTheme.textWarning.opacity(0.1))
            Spacer()
        }
    }
}

// MARK: - Tmux Unavailable Overlay

private struct TmuxUnavailableOverlay: View {
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Text("[!]")
                    .font(Typography.monoLabelBold)
                    .foregroundColor(SoyehtTheme.textWarning)
                Text("session has no tmux - remote scroll unavailable")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textWarning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(SoyehtTheme.textWarning.opacity(0.1))
            Spacer()
        }
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
