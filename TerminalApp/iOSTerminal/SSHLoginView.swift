import SwiftUI
import SwiftTerm

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

                switch tmuxScrollState {
                case .loading:
                    TmuxLoadingOverlay().transition(.opacity)
                case .active(let content):
                    TmuxHistoryView(content: content, onReturn: {
                        withAnimation { tmuxScrollState = .none }
                        NotificationCenter.default.post(name: .soyehtTerminalResumeLive, object: nil)
                    }).transition(.opacity)
                case .error(let message):
                    TmuxErrorOverlay(message: message, onDismiss: {
                        withAnimation { tmuxScrollState = .none }
                        NotificationCenter.default.post(name: .soyehtTerminalResumeLive, object: nil)
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

// MARK: - Tmux History View (capture-pane viewer with multiple modes)

private struct TmuxHistoryView: View {
    let content: String
    let onReturn: () -> Void

    @State private var viewMode: HistoryViewMode = .terminal

    enum HistoryViewMode: String, CaseIterable {
        case scroll, terminal
    }

    private var lineCount: Int {
        content.components(separatedBy: "\n").count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with mode selector
            HStack(spacing: 6) {
                Text("[history] \(lineCount)")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)

                Spacer()

                ForEach(HistoryViewMode.allCases, id: \.self) { mode in
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode } }) {
                        Text(mode.rawValue)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(viewMode == mode ? .black : SoyehtTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    viewMode == mode ? SoyehtTheme.accentGreen : SoyehtTheme.bgSecondary
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onReturn) {
                    Text("voltar ao vivo")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(SoyehtTheme.accentGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(SoyehtTheme.bgTertiary.opacity(0.95))

            // Content based on mode
            switch viewMode {
            case .scroll:
                ScrollHistoryContent(content: content)
            case .terminal:
                TerminalHistoryContent(content: content)
            }
        }
    }
}

// MARK: - Mode: Scroll (ANSI colored, 2D scroll, no wrap)

private struct ScrollHistoryContent: View {
    let content: String

    private var lines: [String] { content.components(separatedBy: "\n") }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(ANSIParser.parse(line.isEmpty ? " " : line))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                }
            }
        }
        .background(SoyehtTheme.bgPrimary)
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

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        let tv = ReadOnlyTerminalView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        tv.backgroundColor = .black
        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = .black

        // Large scrollback to hold all history
        let terminal = tv.getTerminal()
        terminal.changeScrollback(50000)

        // Feed content (\n → \r\n for proper terminal line breaks)
        let normalized = content.replacingOccurrences(of: "\n", with: "\r\n")
        let bytes = Array(normalized.utf8)
        tv.feed(byteArray: bytes[...])

        return tv
    }

    func updateUIView(_ uiView: ReadOnlyTerminalView, context: Context) {}
}

// MARK: - ANSI Escape Code Parser

private enum ANSIParser {
    private typealias SColor = SwiftUI.Color

    static func parse(_ text: String) -> AttributedString {
        var result = AttributedString()
        var fg: SColor = .white
        var bold = false
        var buffer = ""

        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{1b}" {
                // Flush buffer
                if !buffer.isEmpty {
                    result.append(styled(buffer, fg: fg, bold: bold))
                    buffer = ""
                }
                // Try to parse CSI: ESC [ params m
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "[" {
                    var paramStr = ""
                    var j = text.index(after: next)
                    while j < text.endIndex && (text[j].isNumber || text[j] == ";") {
                        paramStr.append(text[j])
                        j = text.index(after: j)
                    }
                    if j < text.endIndex && text[j] == "m" {
                        applySGR(paramStr, fg: &fg, bold: &bold)
                        i = text.index(after: j)
                        continue
                    }
                    // Skip unrecognized CSI sequences
                    if j < text.endIndex && text[j].isLetter {
                        i = text.index(after: j)
                        continue
                    }
                }
                i = text.index(after: i)
            } else {
                buffer.append(text[i])
                i = text.index(after: i)
            }
        }
        if !buffer.isEmpty { result.append(styled(buffer, fg: fg, bold: bold)) }
        return result
    }

    private static func styled(_ text: String, fg: SColor, bold: Bool) -> AttributedString {
        var attr = AttributedString(text)
        attr.foregroundColor = fg
        attr.font = .system(size: 11, weight: bold ? .bold : .regular, design: .monospaced)
        return attr
    }

    private static func applySGR(_ params: String, fg: inout SColor, bold: inout Bool) {
        let codes = params.split(separator: ";").compactMap { Int($0) }
        if codes.isEmpty { fg = .white; bold = false; return }

        var idx = 0
        while idx < codes.count {
            let c = codes[idx]
            switch c {
            case 0: fg = .white; bold = false
            case 1: bold = true
            case 2, 22: bold = false
            case 30...37: fg = color8(c - 30)
            case 39: fg = .white
            case 90...97: fg = colorBright(c - 90)
            case 38:
                if idx + 1 < codes.count && codes[idx + 1] == 5 && idx + 2 < codes.count {
                    fg = color256(codes[idx + 2]); idx += 2
                } else if idx + 1 < codes.count && codes[idx + 1] == 2 && idx + 4 < codes.count {
                    fg = SColor(red: Double(codes[idx+2])/255, green: Double(codes[idx+3])/255, blue: Double(codes[idx+4])/255)
                    idx += 4
                }
            default: break
            }
            idx += 1
        }
    }

    private static func color8(_ i: Int) -> SColor {
        [SColor(red: 0, green: 0, blue: 0),
         SColor(red: 0.8, green: 0.2, blue: 0.2),
         SColor(red: 0.2, green: 0.8, blue: 0.2),
         SColor(red: 0.8, green: 0.8, blue: 0.2),
         SColor(red: 0.3, green: 0.3, blue: 0.9),
         SColor(red: 0.8, green: 0.2, blue: 0.8),
         SColor(red: 0.2, green: 0.8, blue: 0.8),
         SColor(red: 0.75, green: 0.75, blue: 0.75)][min(i, 7)]
    }

    private static func colorBright(_ i: Int) -> SColor {
        [SColor(white: 0.5),
         SColor(red: 1, green: 0.33, blue: 0.33),
         SColor(red: 0.33, green: 1, blue: 0.33),
         SColor(red: 1, green: 1, blue: 0.33),
         SColor(red: 0.4, green: 0.4, blue: 1),
         SColor(red: 1, green: 0.33, blue: 1),
         SColor(red: 0.33, green: 1, blue: 1),
         .white][min(i, 7)]
    }

    private static func color256(_ i: Int) -> SColor {
        if i < 8 { return color8(i) }
        if i < 16 { return colorBright(i - 8) }
        if i < 232 {
            let adj = i - 16
            let r = adj / 36, g = (adj % 36) / 6, b = adj % 6
            return SColor(
                red: r == 0 ? 0 : Double(r * 40 + 55) / 255,
                green: g == 0 ? 0 : Double(g * 40 + 55) / 255,
                blue: b == 0 ? 0 : Double(b * 40 + 55) / 255)
        }
        let gray = Double((i - 232) * 10 + 8) / 255
        return SColor(white: gray)
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
    static let soyehtTerminalResumeLive = Notification.Name("soyehtTerminalResumeLive")
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
