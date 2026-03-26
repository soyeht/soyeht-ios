import SwiftUI

// MARK: - Simulator Configuration

private enum SimulatorConfig {
    static let apiHost = "admin.soyeht.com"
    static let sessionToken = "grkE2Y9KcGLHDP4hCue0elGVIZ0cuy08eLtOq0WI7MA"
    static let expiresAt = "2027-03-26T00:00:00Z"
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
                    onScanned: { token, host in
                        Task { await handleQRScanned(token: token, host: host) }
                    },
                    onCancel: {
                        // If session exists, go to instance list; otherwise stay
                        if store.loadSession() != nil {
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
                    }
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
                    }
                )
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Auth Flow

    private func handlePostSplash() async {
        #if targetEnvironment(simulator)
        // Simulator shortcut: pre-configure session
        store.saveSession(
            token: SimulatorConfig.sessionToken,
            host: SimulatorConfig.apiHost,
            expiresAt: SimulatorConfig.expiresAt
        )
        await MainActor.run {
            withAnimation { appState = .instanceList }
        }
        return
        #endif

        // Check for existing session
        if store.loadSession() != nil {
            let valid = try? await apiClient.validateSession()
            await MainActor.run {
                withAnimation {
                    appState = (valid == true) ? .instanceList : .qrScanner
                }
            }
        } else {
            await MainActor.run {
                withAnimation { appState = .qrScanner }
            }
        }
    }

    private func handleQRScanned(token: String, host: String) async {
        do {
            let _ = try await apiClient.auth(qrToken: token, host: host)
            await MainActor.run {
                withAnimation { appState = .instanceList }
            }
        } catch {
            // Auth failed - stay on QR scanner, error shown in future iteration
        }
    }
}

// MARK: - Terminal Container View

private struct TerminalContainerView: View {
    let wsUrl: String
    let instance: SoyehtInstance
    let sessionName: String
    let onDisconnect: () -> Void

    @State private var tmuxScrollState: TmuxScrollState = .none
    @State private var activeTab: Int = 0
    @State private var tmuxWindows: [TmuxWindow] = []

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
        VStack(spacing: 0) {
            TerminalNavBar(instance: instance, onBack: onDisconnect)
            TmuxTabBar(
                tabs: tmuxWindows.isEmpty ? [] : tmuxWindows.map { "\($0.displayIndex):\($0.displayName)" },
                activeIndex: $activeTab
            )

            ZStack {
                WebSocketTerminalRepresentable(wsUrl: wsUrl)

                if tmuxScrollState == .none {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ModeIndicator(mode: "input")
                                .padding(.trailing, 12)
                                .padding(.bottom, 8)
                        }
                    }
                }

                switch tmuxScrollState {
                case .loading:
                    TmuxLoadingOverlay().transition(.opacity)
                case .active(let content):
                    TmuxHistoryView(content: content, onReturn: {
                        withAnimation { tmuxScrollState = .none }
                    }).transition(.opacity)
                case .error(let message):
                    TmuxErrorOverlay(message: message, onDismiss: {
                        withAnimation { tmuxScrollState = .none }
                    }).transition(.move(edge: .top).combined(with: .opacity))
                case .unavailable:
                    TmuxUnavailableOverlay().transition(.move(edge: .top).combined(with: .opacity))
                case .none:
                    EmptyView()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtScrollTmuxTapped)) { _ in
            withAnimation { tmuxScrollState = .loading }
            Task {
                do {
                    let content = try await SoyehtAPIClient.shared.capturePaneContent(
                        container: instance.container,
                        session: sessionName
                    )
                    await MainActor.run {
                        withAnimation { tmuxScrollState = .active(content: content) }
                    }
                } catch {
                    await MainActor.run {
                        withAnimation { tmuxScrollState = .error(message: error.localizedDescription) }
                    }
                }
            }
        }
        .task {
            do {
                tmuxWindows = try await SoyehtAPIClient.shared.listWindows(
                    container: instance.container,
                    session: sessionName
                )
            } catch {
                tmuxWindows = []
            }
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

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Text(instance.name)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            Circle()
                .fill(instance.isOnline ? SoyehtTheme.statusOnline : SoyehtTheme.statusOffline)
                .frame(width: 6, height: 6)

            Spacer()

            Text(instance.displayTag)
                .font(SoyehtTheme.tagFont)
                .foregroundColor(SoyehtTheme.textSecondary)

            Button(action: {}) {
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

    var body: some View {
        if !tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button(action: { activeIndex = index }) {
                            HStack(spacing: 6) {
                                if index == activeIndex {
                                    Circle()
                                        .fill(SoyehtTheme.accentGreen)
                                        .frame(width: 6, height: 6)
                                }
                                Text(tab)
                                    .font(SoyehtTheme.labelFont)
                                    .foregroundColor(index == activeIndex ? .white : SoyehtTheme.textSecondary)
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

private struct ModeIndicator: View {
    let mode: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(SoyehtTheme.accentGreen)
                .frame(width: 6, height: 6)
            Text(mode)
                .font(SoyehtTheme.tagFont)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(SoyehtTheme.bgSecondary.opacity(0.9))
                )
        )
    }
}

// MARK: - Tmux Loading Overlay

private struct TmuxLoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 16) {
                ProgressView()
                    .tint(SoyehtTheme.accentGreen)
                    .scaleEffect(1.2)
                Text("capturando historico...")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text("tmux capture-pane")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
        }
    }
}

// MARK: - Tmux History View (capture-pane viewer)

private struct TmuxHistoryView: View {
    let content: String
    let onReturn: () -> Void

    private var lines: [String] {
        content.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("[history] \(lines.count) lines")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
                Spacer()
                Button(action: onReturn) {
                    Text("voltar ao vivo")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(SoyehtTheme.accentGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(SoyehtTheme.bgTertiary.opacity(0.95))

            // Scrollable content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                                .id(index)
                        }
                    }
                }
                .onAppear {
                    // Scroll to bottom (most recent content visible)
                    if lines.count > 1 {
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }
            .background(SoyehtTheme.bgPrimary)
        }
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

// MARK: - Notification

extension Notification.Name {
    static let soyehtScrollTmuxTapped = Notification.Name("soyehtScrollTmuxTapped")
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
