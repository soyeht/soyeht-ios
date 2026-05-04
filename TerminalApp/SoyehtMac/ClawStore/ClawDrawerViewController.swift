import AppKit
import SwiftUI
import SoyehtCore

@MainActor
final class ClawDrawerViewController: NSViewController {
    var onDismiss: (() -> Void)?

    private let viewModel = ClawDrawerViewModel()
    private var hostingController: NSHostingController<ClawDrawerRootView>?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacTheme.surfaceBase.cgColor
        root.layer?.masksToBounds = false
        root.layer?.shadowColor = SidebarTokens.shadowColor.cgColor
        root.layer?.shadowOpacity = SidebarTokens.shadowOpacity
        root.layer?.shadowOffset = NSSize(width: -4, height: 0)
        root.layer?.shadowRadius = SidebarTokens.shadowRadius
        self.view = root

        let host = NSHostingController(rootView: ClawDrawerRootView(
            viewModel: viewModel,
            onShowConnectedServers: {
                Task { @MainActor in
                    (NSApp.delegate as? AppDelegate)?.showConnectedServers(nil)
                }
            },
            onDismiss: { [weak self] in self?.onDismiss?() }
        ))
        // Drawer is hosted inside a fixed-width AppKit overlay. Don't let
        // SwiftUI's ideal size propagate up the responder chain — the
        // window's content size must stay independent of whatever route
        // the SwiftUI tree is rendering.
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: root.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        hostingController = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: .preferencesDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refresh() {
        viewModel.refresh()
    }

    func applyTheme() {
        view.layer?.backgroundColor = MacTheme.surfaceBase.cgColor
        view.layer?.shadowColor = SidebarTokens.shadowColor.cgColor
    }

    @objc private func preferencesDidChange() {
        applyTheme()
    }
}

@MainActor
private final class ClawDrawerViewModel: ObservableObject {
    @Published private(set) var context: ServerContext?
    @Published private(set) var rows: [ClawDrawerRow] = []
    @Published private(set) var catalogClaws: [Claw] = []
    @Published private(set) var isLoading = false
    @Published private(set) var installingClaws: Set<String> = []
    /// Whether theyOS is staged on this Mac (Homebrew Cellar/symlink check).
    /// Drives footer-link visibility: the "Uninstall theyOS from this Mac"
    /// affordance must not render when there's nothing to uninstall.
    /// Initial value is the live probe so the first render is correct;
    /// subsequent updates happen inside `refresh()`.
    @Published private(set) var theyOSInstalled: Bool = TheyOSEnvironment.isTheyOSInstalled()
    @Published var errorMessage: String?
    @Published var actionError: String?

    private let apiClient: SoyehtAPIClient
    private let sessionStore: SessionStore
    private var loadTask: Task<Void, Never>?

    init(apiClient: SoyehtAPIClient = .shared, sessionStore: SessionStore = .shared) {
        self.apiClient = apiClient
        self.sessionStore = sessionStore
    }

    deinit {
        loadTask?.cancel()
    }

    func refresh() {
        loadTask?.cancel()
        theyOSInstalled = TheyOSEnvironment.isTheyOSInstalled()
        context = sessionStore.currentContext()
        guard let context else {
            rows = []
            catalogClaws = []
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.loadTask = nil
            }

            do {
                async let clawsFetch = self.apiClient.getClaws(context: context)
                async let instancesFetch = self.apiClient.getInstances(context: context)
                let (claws, instances) = try await (clawsFetch, instancesFetch)
                guard !Task.isCancelled else { return }
                self.catalogClaws = claws.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                self.rows = Self.makeRows(claws: claws, instances: instances, context: context)
                self.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                let cachedInstances = self.sessionStore.loadInstances()
                self.rows = Self.makeRows(claws: self.catalogClaws, instances: cachedInstances, context: context)
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func install(_ claw: Claw) {
        guard let context, !installingClaws.contains(claw.name) else { return }
        installingClaws.insert(claw.name)
        actionError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.installingClaws.remove(claw.name) }
            do {
                _ = try await self.apiClient.installClaw(name: claw.name, context: context)
                NotificationCenter.default.post(name: ClawStoreNotifications.installedSetChanged, object: nil)
                self.refresh()
            } catch {
                self.actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private static func makeRows(
        claws: [Claw],
        instances: [SoyehtInstance],
        context: ServerContext
    ) -> [ClawDrawerRow] {
        return instances
            .filter { $0.clawType != nil }
            .sorted {
                if $0.isOnline != $1.isOnline { return $0.isOnline && !$1.isOnline }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { instance -> ClawDrawerRow in
                let type = instance.clawType ?? "claw"
                let status = ClawDrawerStatus(instance: instance)
                let title = instance.name.isEmpty ? type : instance.name
                let subtitle: String = {
                    if instance.isProvisioning { return "provisioning" }
                    if instance.isOnline { return context.server.name }
                    return instance.status ?? "offline"
                }()
                return ClawDrawerRow(
                    id: instance.id,
                    title: title,
                    subtitle: subtitle,
                    badge: "[\(type)]",
                    searchToken: type,
                    status: status
                )
            }
    }
}

private struct ClawDrawerRootView: View {
    @ObservedObject var viewModel: ClawDrawerViewModel
    let onShowConnectedServers: () -> Void
    let onDismiss: () -> Void

    @State private var route: ClawDrawerRoute = .claws
    @State private var clawsSearchText = ""
    @State private var storeSearchText = ""
    @State private var themeFingerprint = Self.currentThemeFingerprint()

    var body: some View {
        content
            .id(themeFingerprint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ClawDrawerTokens.background)
            .preferredColorScheme(MacClawStoreTheme.preferredColorScheme)
            .onAppear { viewModel.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .preferencesDidChange)) { _ in
                themeFingerprint = Self.currentThemeFingerprint()
            }
            .onReceive(NotificationCenter.default.publisher(for: ClawStoreNotifications.activeServerChanged)) { _ in
                route = .claws
                viewModel.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: ClawStoreNotifications.installedSetChanged)) { _ in
                viewModel.refresh()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .claws:
            if viewModel.context == nil {
                theyOSMissingView
            } else {
                clawsListView
            }
        case .store:
            if viewModel.context == nil {
                theyOSMissingView
            } else {
                storeView
            }
        case .installMac:
            installMacView
        case .connectServer:
            connectServerView
        case .uninstallTheyOS:
            uninstallTheyOSView
        }
    }

    private var clawsListView: some View {
        VStack(spacing: 0) {
            header(title: "// claws")
            searchField(text: $clawsSearchText, placeholder: "search claws")

            if viewModel.isLoading && viewModel.rows.isEmpty {
                loadingView
            } else if filteredRows.isEmpty {
                emptyRowsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredRows) { row in
                            Button {
                                storeSearchText = row.searchToken
                                route = .store
                            } label: {
                                ClawDrawerRowView(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }

            if let error = viewModel.errorMessage, !viewModel.rows.isEmpty {
                Text(error)
                    .font(MacTypography.Fonts.drawerError)
                    .foregroundColor(ClawDrawerTokens.warning)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Button {
                storeSearchText = ""
                route = .store
            } label: {
                HStack {
                    Image(systemName: "storefront")
                    Text("claw store")
                        .font(MacTypography.Fonts.drawerCTA)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(MacTypography.Fonts.drawerCTAIcon)
                }
                .foregroundColor(ClawDrawerTokens.buttonTextOnAccent)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(ClawDrawerTokens.accent)
            }
            .buttonStyle(.plain)

            uninstallTheyOSEntryButton
        }
    }

    /// Subtle text-link entry to the complete uninstall flow. Lives at the
    /// very bottom of every claws-context route so it's always reachable
    /// without competing with the primary "claw store" CTA.
    private var uninstallTheyOSEntryButton: some View {
        Button {
            route = .uninstallTheyOS
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(MacTypography.Fonts.drawerLinkIcon)
                Text("drawer.button.uninstallTheyOS")
                    .font(MacTypography.Fonts.drawerLinkText)
                Spacer()
            }
            .foregroundColor(ClawDrawerTokens.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(ClawDrawerTokens.background)
        }
        .buttonStyle(.plain)
        .help("drawer.uninstallTheyOS.subtitle")
    }

    private var theyOSMissingView: some View {
        VStack(spacing: 0) {
            header(title: "// claws")
            Spacer(minLength: 18)
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(MacTypography.Fonts.drawerHeroIcon)
                    .foregroundColor(ClawDrawerTokens.accent)
                    .frame(width: 52, height: 52)
                    .background(ClawDrawerTokens.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 8) {
                    Text("theyOS not installed")
                        .font(MacTypography.Fonts.drawerTitle)
                        .foregroundColor(ClawDrawerTokens.textPrimary)
                    Text("Install theyOS to manage your claws. Choose an option below:")
                        .font(MacTypography.Fonts.drawerBody)
                        .foregroundColor(ClawDrawerTokens.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    drawerButton(title: "Activate via Mac", systemImage: "desktopcomputer") {
                        route = .installMac
                    }
                    drawerButton(title: "Connect to server", systemImage: "link") {
                        route = .connectServer
                    }
                }
            }
            .padding(18)
            .background(ClawDrawerTokens.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ClawDrawerTokens.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            Spacer(minLength: 18)
            // Hide the uninstall affordance when theyOS isn't actually
            // staged on this Mac — clicking it from this state would just
            // throw `homebrewMissing` and confuse the user.
            if viewModel.theyOSInstalled {
                uninstallTheyOSEntryButton
            }
        }
    }

    private var storeView: some View {
        VStack(spacing: 0) {
            header(title: "// claw store", showsBack: true)
            searchField(text: $storeSearchText, placeholder: "search store")

            if viewModel.isLoading && viewModel.catalogClaws.isEmpty {
                loadingView
            } else if filteredCatalogClaws.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(MacTypography.Fonts.drawerEmptyIcon)
                        .foregroundColor(ClawDrawerTokens.textMuted)
                    Text("No claws found")
                        .font(MacTypography.Fonts.drawerEmptyTitle)
                        .foregroundColor(ClawDrawerTokens.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredCatalogClaws) { claw in
                            CompactClawStoreRow(
                                claw: claw,
                                isInstalling: viewModel.installingClaws.contains(claw.name),
                                onInstall: { viewModel.install(claw) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }

            if let error = viewModel.actionError {
                Text(error)
                    .font(MacTypography.Fonts.drawerError)
                    .foregroundColor(ClawDrawerTokens.warning)
                    .lineLimit(3)
                    .padding(12)
            }
        }
    }

    private var installMacView: some View {
        VStack(spacing: 0) {
            header(title: "activate theyOS", showsBack: true)
            ScrollView {
                LocalInstallView(onPaired: handlePaired, compact: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var connectServerView: some View {
        VStack(spacing: 0) {
            header(title: "connect server", showsBack: true)
            ScrollView {
                RemoteConnectView(onPaired: handlePaired, compact: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var uninstallTheyOSView: some View {
        VStack(spacing: 0) {
            header(title: "remove theyOS", showsBack: true)
            ScrollView {
                UninstallTheyOSView(onCompleted: handleUninstallCompleted, compact: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(ClawDrawerTokens.accent)
                .scaleEffect(0.8)
            Text("loading")
                .font(MacTypography.Fonts.drawerLoading)
                .foregroundColor(ClawDrawerTokens.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyRowsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(MacTypography.Fonts.drawerEmptyIcon)
                .foregroundColor(ClawDrawerTokens.textMuted)
            Text(viewModel.errorMessage ?? "No claws running")
                .font(MacTypography.Fonts.drawerEmptyTitle)
                .foregroundColor(ClawDrawerTokens.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredRows: [ClawDrawerRow] {
        let needle = clawsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return viewModel.rows }
        return viewModel.rows.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
            || $0.subtitle.localizedCaseInsensitiveContains(needle)
            || $0.badge.localizedCaseInsensitiveContains(needle)
        }
    }

    private var filteredCatalogClaws: [Claw] {
        let needle = storeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return viewModel.catalogClaws }
        return viewModel.catalogClaws.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
            || $0.language.localizedCaseInsensitiveContains(needle)
            || $0.description.localizedCaseInsensitiveContains(needle)
        }
    }

    private func header(title: String, showsBack: Bool = false) -> some View {
        HStack(spacing: 8) {
            if showsBack {
                iconButton(systemName: "chevron.left", action: { route = .claws })
            }
            Text(title)
                .font(MacTypography.Fonts.drawerHeader)
                .foregroundColor(ClawDrawerTokens.textPrimary)
            Spacer()
            iconButton(systemName: "server.rack", action: onShowConnectedServers)
                .help("Connected Servers")
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(MacTypography.Fonts.drawerToolbarIcon)
                    .frame(width: 24, height: 24)
                    .foregroundColor(ClawDrawerTokens.textMuted)
            }
            .buttonStyle(.plain)
            iconButton(systemName: "xmark", action: onDismiss)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(ClawDrawerTokens.background)
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(MacTypography.Fonts.drawerToolbarIcon)
                .frame(width: 24, height: 24)
                .foregroundColor(ClawDrawerTokens.textMuted)
        }
        .buttonStyle(.plain)
    }

    private func searchField(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(MacTypography.Fonts.drawerSearchIcon)
                .foregroundColor(ClawDrawerTokens.textMuted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(MacTypography.Fonts.drawerSearchText)
                .foregroundColor(ClawDrawerTokens.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(ClawDrawerTokens.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ClawDrawerTokens.stroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func drawerButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(MacTypography.Fonts.drawerButton)
                Text(title)
                    .font(MacTypography.Fonts.drawerButton)
                Spacer()
            }
            .foregroundColor(ClawDrawerTokens.buttonTextOnAccent)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(ClawDrawerTokens.accent)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func handlePaired() {
        route = .claws
        viewModel.refresh()
    }

    private func handleUninstallCompleted() {
        // After a successful uninstall the SessionStore is empty, so the
        // claws route will render `theyOSMissingView` automatically. Just
        // bounce back there and refresh — the missing-view re-fetch is a
        // no-op when there's no server to talk to.
        route = .claws
        viewModel.refresh()
    }

    private static func currentThemeFingerprint() -> String {
        let theme = TerminalColorTheme.active
        return ([theme.id] + theme.appPalette.allHexValues).joined(separator: "|")
    }
}

private struct ClawDrawerRowView: View {
    let row: ClawDrawerRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(row.status.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(MacTypography.Fonts.drawerRowTitle)
                    .foregroundColor(ClawDrawerTokens.textPrimary)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(MacTypography.Fonts.drawerRowSubtitle)
                    .foregroundColor(ClawDrawerTokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.badge)
                .font(MacTypography.Fonts.drawerRowBadge)
                .foregroundColor(ClawDrawerTokens.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(ClawDrawerTokens.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ClawDrawerTokens.stroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CompactClawStoreRow: View {
    let claw: Claw
    let isInstalling: Bool
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(claw.name)
                        .font(MacTypography.Fonts.drawerRowTitle)
                        .foregroundColor(ClawDrawerTokens.textPrimary)
                        .lineLimit(1)
                    Text(claw.description)
                        .font(MacTypography.Fonts.drawerRowSubtitle)
                        .foregroundColor(ClawDrawerTokens.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text("[\(claw.language)]")
                    .font(MacTypography.Fonts.drawerStoreLanguage)
                    .foregroundColor(ClawDrawerTokens.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            HStack(spacing: 8) {
                Text(stateLabel)
                    .font(MacTypography.Fonts.drawerStoreStatus)
                    .foregroundColor(stateColor)
                Spacer()
                if canInstall {
                    Button(action: onInstall) {
                        Text(isInstalling ? "installing" : "install")
                            .font(MacTypography.Fonts.drawerStoreInstall)
                            .foregroundColor(ClawDrawerTokens.buttonTextOnAccent)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(ClawDrawerTokens.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(isInstalling)
                }
            }
        }
        .padding(10)
        .background(ClawDrawerTokens.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ClawDrawerTokens.stroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var canInstall: Bool {
        if isInstalling { return false }
        switch claw.installState {
        case .notInstalled, .installFailed:
            return true
        default:
            return false
        }
    }

    private var stateLabel: String {
        if isInstalling { return "installing" }
        switch claw.installState {
        case .installed:
            return "installed"
        case .installedButBlocked:
            return "installed"
        case .installing:
            return "installing"
        case .uninstalling:
            return "uninstalling"
        case .installFailed:
            return "failed"
        case .notInstalled:
            return "not installed"
        case .unknown:
            return "unknown"
        }
    }

    private var stateColor: Color {
        switch claw.installState {
        case .installed, .installedButBlocked:
            return ClawDrawerTokens.accent
        case .installFailed:
            return ClawDrawerTokens.warning
        default:
            return ClawDrawerTokens.textMuted
        }
    }
}

private struct ClawDrawerRow: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String
    let searchToken: String
    let status: ClawDrawerStatus
}

private enum ClawDrawerStatus: Hashable {
    case online
    case provisioning
    case idle

    init(instance: SoyehtInstance) {
        if instance.isProvisioning {
            self = .provisioning
        } else if instance.isOnline {
            self = .online
        } else {
            self = .idle
        }
    }

    var color: Color {
        switch self {
        case .online:
            return ClawDrawerTokens.accent
        case .provisioning:
            return ClawDrawerTokens.warning
        case .idle:
            return ClawDrawerTokens.textMuted
        }
    }
}

private enum ClawDrawerRoute {
    case claws
    case store
    case installMac
    case connectServer
    case uninstallTheyOS
}

private enum ClawDrawerTokens {
    static var background: Color { MacClawStoreTheme.bgPrimary }
    static var panel: Color { MacClawStoreTheme.bgCard }
    static var stroke: Color { MacClawStoreTheme.readableStroke }
    static var accent: Color { MacClawStoreTheme.statusGreen }
    static var warning: Color { MacClawStoreTheme.accentAmber }
    static var textPrimary: Color { MacClawStoreTheme.textPrimary }
    static var textMuted: Color { MacClawStoreTheme.textMuted }
    static var buttonTextOnAccent: Color { MacClawStoreTheme.buttonTextOnAccent }
}
