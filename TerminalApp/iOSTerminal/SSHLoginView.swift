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
        case terminal(wsUrl: String, SoyehtInstance)
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
                    onConnect: { wsUrl, instance in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            appState = .terminal(wsUrl: wsUrl, instance)
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

            case .terminal(let wsUrl, let instance):
                TerminalContainerView(
                    wsUrl: wsUrl,
                    instance: instance,
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
    let onDisconnect: () -> Void

    @State private var tmuxScrollState: TmuxScrollState = .none
    @State private var activeTab: Int = 0

    enum TmuxScrollState {
        case none
        case entering
        case active
        case unavailable
    }

    private let mockTabs = ["0:claude", "1:bash", "2:htop"]

    var body: some View {
        VStack(spacing: 0) {
            TerminalNavBar(instance: instance, onBack: onDisconnect)
            TmuxTabBar(tabs: mockTabs, activeIndex: $activeTab)

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
                case .entering:
                    TmuxEnteringOverlay().transition(.opacity)
                case .active:
                    TmuxActiveOverlay(onReturn: {
                        withAnimation { tmuxScrollState = .none }
                    }).transition(.opacity)
                case .unavailable:
                    TmuxUnavailableOverlay().transition(.move(edge: .top).combined(with: .opacity))
                case .none:
                    EmptyView()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtScrollTmuxTapped)) { _ in
            withAnimation { tmuxScrollState = .entering }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { tmuxScrollState = .active }
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

// MARK: - Tmux Mock Overlays

private struct TmuxEnteringOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 16) {
                Text(">>")
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(SoyehtTheme.accentGreen)
                Text("entrando em copy-mode")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text("preparando navegacao de historico...")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
        }
    }
}

private struct TmuxActiveOverlay: View {
    let onReturn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("[copy-mode] line 047/1203")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
                Spacer()
                Text("return to scroll")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.accentGreen)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(SoyehtTheme.bgTertiary.opacity(0.95))

            Spacer()

            HStack(spacing: 12) {
                ScrollControlButton(label: "PgUp")
                ScrollControlButton(icon: "chevron.up")
                ScrollControlButton(icon: "chevron.down")
                ScrollControlButton(label: "PgDn")
                Spacer()
                Button(action: onReturn) {
                    Text("voltar ao vivo")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(SoyehtTheme.accentGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(SoyehtTheme.bgTertiary.opacity(0.95))
        }
    }
}

private struct ScrollControlButton: View {
    var label: String?
    var icon: String?

    var body: some View {
        Button(action: {}) {
            Group {
                if let label { Text(label).font(SoyehtTheme.tagFont) }
                else if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
            }
            .foregroundColor(.white)
            .frame(width: 44, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SoyehtTheme.bgSecondary)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

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
