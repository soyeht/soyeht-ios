import SwiftUI
import SwiftTerm

// MARK: - Simulator Configuration

private enum SimulatorConfig {
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
        case terminal(wsUrl: String, SoyehtInstance, sessionName: String)
    }

    @State private var appState: AppState = .splash
    @State private var autoSelectInstance: SoyehtInstance?
    @State private var successMessage: String?

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
                    onConnect: { wsUrl, instance, sessionName in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .terminal(wsUrl: wsUrl, instance, sessionName: sessionName)
                        }
                    },
                    onAddInstance: {
                        withAnimation { appState = .qrScanner }
                    },
                    onLogout: {
                        Task {
                            try? await apiClient.logout()
                            withAnimation { appState = .qrScanner }
                        }
                    },
                    autoSelectInstance: $autoSelectInstance
                )
                .transition(.opacity)

            case .terminal(let wsUrl, let instance, let sessionName):
                TerminalContainerView(
                    wsUrl: wsUrl,
                    instance: instance,
                    sessionName: sessionName,
                    onDisconnect: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .instanceList
                        }
                    },
                    onConnectionLost: {
                        autoSelectInstance = instance
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
    }

    // MARK: - Auth Flow

    private func handlePostSplash() async {
        #if targetEnvironment(simulator)
        // Simulator shortcut: pre-configure as a paired server
        let simHost = SimulatorConfig.apiHost
        let simToken = SimulatorConfig.sessionToken
        if !simHost.isEmpty, !simToken.isEmpty, !store.pairedServers.contains(where: { $0.host == simHost }) {
            let server = PairedServer(
                id: UUID().uuidString,
                host: simHost,
                name: "simulator",
                role: "admin",
                pairedAt: Date(),
                expiresAt: SimulatorConfig.expiresAt
            )
            store.addServer(server, token: simToken)
            store.setActiveServer(id: server.id)
        }
        await MainActor.run {
            withAnimation { appState = .instanceList }
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
            let valid = (try? await apiClient.validateSession()) ?? false
            await MainActor.run {
                withAnimation {
                    appState = valid ? .instanceList : .qrScanner
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
                // Pair failed - stay on QR scanner
            }

        case .connect(let token, let host):
            do {
                let _ = try await apiClient.auth(qrToken: token, host: host)
                await showSuccessAndNavigate(message: "connected successfully")
            } catch {
                // Auth failed - stay on QR scanner
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
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(SoyehtTheme.accentGreen)

                Text(message)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textPrimary)
            }
        }
    }
}

// MARK: - Terminal Container View

private struct TerminalContainerView: View {
    let wsUrl: String
    let instance: SoyehtInstance
    let sessionName: String
    let onDisconnect: () -> Void
    let onConnectionLost: () -> Void

    @State private var tmuxScrollState: TmuxScrollState = .none
    @State private var activePaneIndex: Int = 0
    @State private var activeWindowIndex: Int = 0
    @State private var tmuxPanes: [TmuxPane] = []
    @State private var fetchTask: Task<Void, Never>?
    @State private var showSettings = false

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
            TerminalNavBar(instance: instance, onBack: onDisconnect, onSettings: { showSettings = true })
            TmuxTabBar(
                tabs: tmuxPanes.map { pane in
                    let prefs = TerminalPreferences.shared
                    if let nick = prefs.paneNickname(
                        container: instance.container,
                        session: sessionName,
                        window: activeWindowIndex,
                        pane: pane.index
                    ) {
                        return nick
                    }
                    return "\(pane.index):\(pane.command)"
                },
                activeIndex: $activePaneIndex,
                onTabSelected: { index in Task { await switchToPane(index) } }
            )

            ZStack {
                WebSocketTerminalRepresentable(wsUrl: wsUrl)

                switch tmuxScrollState {
                case .loading:
                    TmuxLoadingOverlay().transition(.opacity)
                case .active(let content):
                    TmuxHistoryView(content: content, onExit: exitHistory).transition(.opacity)
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
            withAnimation { tmuxScrollState = .loading }
            fetchTask?.cancel()
            fetchTask = Task {
                do {
                    let content = try await SoyehtAPIClient.shared.capturePaneContent(
                        container: instance.container,
                        session: sessionName
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
        .onReceive(NotificationCenter.default.publisher(for: .soyehtConnectionLost)) { _ in
            onConnectionLost()
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtSwipePaneNext)) { _ in
            let next = min(activePaneIndex + 1, tmuxPanes.count - 1)
            if next != activePaneIndex { Task { await switchToPane(next) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtSwipePanePrev)) { _ in
            let prev = max(activePaneIndex - 1, 0)
            if prev != activePaneIndex { Task { await switchToPane(prev) } }
        }
        .sheet(isPresented: $showSettings) {
            SettingsRootView()
        }
        .task {
            do {
                let windows = try await SoyehtAPIClient.shared.listWindows(
                    container: instance.container,
                    session: sessionName
                )
                let activeWindow = windows.first(where: { $0.active }) ?? windows.first
                activeWindowIndex = activeWindow?.index ?? 0

                tmuxPanes = try await SoyehtAPIClient.shared.listPanes(
                    container: instance.container,
                    session: sessionName,
                    windowIndex: activeWindowIndex
                )
                if let idx = tmuxPanes.firstIndex(where: { $0.active }) {
                    activePaneIndex = idx
                }
                // Zoom active pane on initial load (fullscreen on mobile)
                if tmuxPanes.count > 1, let activePane = tmuxPanes.first(where: { $0.active }) {
                    try? await SoyehtAPIClient.shared.selectPane(
                        container: instance.container,
                        session: sessionName,
                        windowIndex: activeWindowIndex,
                        paneIndex: activePane.index
                    )
                }
            } catch {
                tmuxPanes = []
            }
        }
    }

    private func switchToPane(_ index: Int) async {
        guard index >= 0, index < tmuxPanes.count else { return }
        let pane = tmuxPanes[index]
        do {
            try await SoyehtAPIClient.shared.selectPane(
                container: instance.container,
                session: sessionName,
                windowIndex: activeWindowIndex,
                paneIndex: pane.index
            )
            activePaneIndex = index
        } catch {
            // Silent fail — terminal stays on current pane
        }
    }
}

// MARK: - WebSocket Terminal Representable

private struct WebSocketTerminalRepresentable: UIViewControllerRepresentable {
    let wsUrl: String

    func makeUIViewController(context: Context) -> TerminalHostViewController {
        let controller = TerminalHostViewController()
        controller.updateWebSocket(wsUrl)
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalHostViewController, context: Context) {
        uiViewController.updateWebSocket(wsUrl)
    }
}

// MARK: - Terminal Nav Bar

private struct TerminalNavBar: View {
    let instance: SoyehtInstance
    let onBack: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Text(instance.name)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(SoyehtTheme.textPrimary)

            Circle()
                .fill(instance.isOnline ? SoyehtTheme.statusOnline : SoyehtTheme.statusOffline)
                .frame(width: 6, height: 6)

            Spacer()

            Text(instance.displayTag)
                .font(SoyehtTheme.tagFont)
                .foregroundColor(SoyehtTheme.textSecondary)

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
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
                            activeIndex = index
                            onTabSelected?(index)
                        }) {
                            HStack(spacing: 6) {
                                if index == activeIndex {
                                    Circle()
                                        .fill(SoyehtTheme.accentGreen)
                                        .frame(width: 6, height: 6)
                                }
                                Text(tab)
                                    .font(SoyehtTheme.labelFont)
                                    .foregroundColor(index == activeIndex ? SoyehtTheme.textPrimary : SoyehtTheme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(SoyehtTheme.bgTertiary)
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
                Text("capturando historico...")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text("tmux capture-pane")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
        }
    }
}

// MARK: - Tmux History View (capture-pane viewer with multiple modes)

private struct TmuxHistoryView: View {
    let content: String
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
                // Mode toggle
                HStack(spacing: 2) {
                    ForEach(HistoryViewMode.allCases, id: \.self) { mode in
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode } }) {
                            Text(mode.rawValue)
                                .font(.system(size: 14, weight: viewMode == mode ? .medium : .regular, design: .monospaced))
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
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
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
                Text("↕ drag to navigate history")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
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

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        let tv = ReadOnlyTerminalView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        SoyehtTerminalAppearance.apply(to: tv)
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let terminal = tv.getTerminal()
        terminal.changeScrollback(50000)

        let normalized = content.replacingOccurrences(of: "\n", with: "\r\n")
        tv.feed(byteArray: Array(normalized.utf8)[...])

        return tv
    }

    func updateUIView(_ uiView: ReadOnlyTerminalView, context: Context) {
        uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textWarning)
                Text("capture-pane: \(message)")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textWarning)
                    .lineLimit(2)
                Spacer()
                Button("dismiss") { onDismiss() }
                    .font(SoyehtTheme.tagFont)
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
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textWarning)
                Text("sessao sem tmux - scroll remoto indisponivel")
                    .font(SoyehtTheme.smallMono)
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
