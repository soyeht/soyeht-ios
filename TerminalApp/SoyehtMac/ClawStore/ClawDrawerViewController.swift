import AppKit
import SwiftUI
import SoyehtCore

@MainActor
final class ClawDrawerViewController: NSViewController {
    var onDismiss: (() -> Void)?

    private let viewModel = ClawDrawerViewModel()
    private var hostingController: NSHostingController<ClawDrawerRootView>?

    override func loadView() {
        let root = MacStyledSurfaceView()
        applyPanelStyle(to: root)
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
        if let root = view as? MacStyledSurfaceView {
            applyPanelStyle(to: root)
        }
    }

    private func applyPanelStyle(to root: MacStyledSurfaceView) {
        let neo = MacSurface.style == .neomorphic
        root.applyStyle(
            fill: neo ? MacTheme.neoWell : MacTheme.surfaceBase,
            gradient: neo ? (MacTheme.neoConvexStart, MacTheme.neoConvexEnd) : nil,
            cornerRadius: neo ? MacSurface.Radius.panel : 0,
            shadows: MacSurface.Shadows.drawerPanelSet
        )
    }

    @objc private func preferencesDidChange() {
        applyTheme()
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
            header(title: String(localized: "drawer.header.claws"))
            searchField(text: $clawsSearchText, placeholder: String(localized: "drawer.search.claws"))

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
                    Text("drawer.button.clawStore")
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
    /// without competing with the primary "Claw Store" CTA.
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
            header(title: String(localized: "drawer.header.claws"))
            Spacer(minLength: 18)
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(MacTypography.Fonts.drawerHeroIcon)
                    .foregroundColor(ClawDrawerTokens.accent)
                    .frame(width: 52, height: 52)
                    .background(ClawDrawerTokens.panel)
                    .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.card))

                VStack(spacing: 8) {
                    Text("drawer.missing.title")
                        .font(MacTypography.Fonts.drawerTitle)
                        .foregroundColor(ClawDrawerTokens.textPrimary)
                    Text("drawer.missing.subtitle")
                        .font(MacTypography.Fonts.drawerBody)
                        .foregroundColor(ClawDrawerTokens.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    drawerButton(title: String(localized: "drawer.missing.activateViaMac"), systemImage: "desktopcomputer") {
                        route = .installMac
                    }
                    drawerButton(title: String(localized: "drawer.missing.connectServer"), systemImage: "link") {
                        route = .connectServer
                    }
                }
            }
            .padding(18)
            .background(ClawDrawerTokens.panel)
            .overlay(
                RoundedRectangle(cornerRadius: MacSurface.Radius.card)
                    .stroke(ClawDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.card))
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
            header(title: String(localized: "drawer.header.clawStore"), showsBack: true)
            if let context = viewModel.context {
                // E1: the store content owns the guest-image readiness gate, keyed
                // to the active server so a server switch rebuilds it (and its poll
                // task) cleanly. `viewModel.context` is non-nil here — the parent
                // `content` switch renders `theyOSMissingView` when it is nil.
                DrawerStoreContent(viewModel: viewModel, context: context, searchText: $storeSearchText)
                    .id(context.serverId)
            }
        }
    }

    private var installMacView: some View {
        VStack(spacing: 0) {
            header(title: String(localized: "drawer.header.activateTheyOS"), showsBack: true)
            ScrollView {
                LocalInstallView(onPaired: handlePaired, compact: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var connectServerView: some View {
        VStack(spacing: 0) {
            header(title: String(localized: "drawer.header.connectServer"), showsBack: true)
            ScrollView {
                RemoteConnectView(onPaired: handlePaired, compact: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var uninstallTheyOSView: some View {
        VStack(spacing: 0) {
            header(title: String(localized: "drawer.header.removeTheyOS"), showsBack: true)
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
            Text(viewModel.errorMessage ?? String(localized: "drawer.empty.noClawsRunning"))
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
                .help("drawer.button.connectedServers.help")
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
            RoundedRectangle(cornerRadius: MacSurface.Radius.control)
                .stroke(ClawDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
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
            .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
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
            RoundedRectangle(cornerRadius: MacSurface.Radius.control)
                .stroke(ClawDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
    }
}

/// E1: the store route's content below the header. Owns the guest-image
/// readiness gate (the parent keys it by `serverId` via `.id`, so a server
/// switch rebuilds it and cancels its poll cleanly) and renders the shared
/// `MacGuestImageRecoveryBanner`, so the drawer's install surface enforces the
/// SAME readiness gate as the dedicated Store window. Catalog data still comes
/// from `ClawDrawerViewModel` — this view adds NO fetch/cache (that is E2).
private struct DrawerStoreContent: View {
    @ObservedObject var viewModel: ClawDrawerViewModel
    let context: ServerContext
    @Binding var searchText: String

    @StateObject private var readiness: MacGuestImageReadinessModel

    init(viewModel: ClawDrawerViewModel, context: ServerContext, searchText: Binding<String>) {
        self.viewModel = viewModel
        self.context = context
        self._searchText = searchText
        self._readiness = StateObject(wrappedValue: MacGuestImageReadinessModel(server: context.server))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            // Reuses the dedicated Store window's recovery banner verbatim — no
            // new copy. Self-gates: renders nothing when install is allowed.
            MacGuestImageRecoveryBanner(
                state: readiness.state,
                onCheckAgain: { Task { await readiness.recheck() } },
                onPrepare: { Task { await readiness.prepare() } },
                isRechecking: readiness.isRechecking,
                isPreparing: readiness.isPreparing
            )
            .padding(.horizontal, 10)

            if viewModel.isLoading && viewModel.catalogClaws.isEmpty {
                loadingView
            } else if filteredClaws.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredClaws) { claw in
                            CompactClawStoreRow(
                                claw: claw,
                                isInstalling: viewModel.installingClaws.contains(claw.name),
                                readiness: readiness.state,
                                onInstall: { viewModel.install(claw, readiness: readiness.state) }
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
        .task { await pollReadiness() }
    }

    private var filteredClaws: [Claw] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return viewModel.catalogClaws }
        return viewModel.catalogClaws.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
            || $0.language.localizedCaseInsensitiveContains(needle)
            || $0.description.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Poll the readiness gate to a terminal state, mirroring
    /// `MacClawStoreRootView.pollReadiness`. The `.task` is cancelled when the
    /// view disappears or its `.id` (serverId) changes, so no poll task leaks
    /// across a server switch.
    private func pollReadiness() async {
        while readiness.state.needsFetch, !Task.isCancelled {
            await readiness.refresh()
            guard readiness.state.needsFetch, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(MacTypography.Fonts.drawerSearchIcon)
                .foregroundColor(ClawDrawerTokens.textMuted)
            TextField(String(localized: "drawer.search.store"), text: $searchText)
                .textFieldStyle(.plain)
                .font(MacTypography.Fonts.drawerSearchText)
                .foregroundColor(ClawDrawerTokens.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(ClawDrawerTokens.panel)
        .overlay(
            RoundedRectangle(cornerRadius: MacSurface.Radius.control)
                .stroke(ClawDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
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

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(MacTypography.Fonts.drawerEmptyIcon)
                .foregroundColor(ClawDrawerTokens.textMuted)
            Text("No claws found")
                .font(MacTypography.Fonts.drawerEmptyTitle)
                .foregroundColor(ClawDrawerTokens.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompactClawStoreRow: View {
    let claw: Claw
    let isInstalling: Bool
    let readiness: MacGuestImageGateState
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
                        Text(LocalizedStringKey(isInstalling ? "drawer.status.installing" : "drawer.button.install"))
                            .font(MacTypography.Fonts.drawerStoreInstall)
                            .foregroundColor(ClawDrawerTokens.buttonTextOnAccent)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(ClawDrawerTokens.accent)
                            .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.chip))
                    }
                    .buttonStyle(.plain)
                    .disabled(isInstalling)
                }
            }
        }
        .padding(10)
        .background(ClawDrawerTokens.panel)
        .overlay(
            RoundedRectangle(cornerRadius: MacSurface.Radius.control)
                .stroke(ClawDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
    }

    private var canInstall: Bool {
        // E1: the drawer's install decision — backend installability (theyos #88)
        // + install-state eligibility + guest-image readiness — so the drawer
        // can't offer an install the dedicated Store window would gate. The drawer
        // row and the drawer install action consult the SAME `MacClawInstallDecision`
        // (no inline re-derivation); it mirrors the Store's readiness gate.
        // Cross-surface convergence is E2.
        MacClawInstallDecision.canOfferInstall(claw: claw, readiness: readiness, isInstalling: isInstalling)
    }

    private var stateLabel: String {
        if isInstalling { return String(localized: "drawer.status.installing") }
        // Non-installable claws read "not available" regardless of install
        // state, taking precedence over the per-state labels below.
        if !claw.installability.isInstallable {
            return String(
                localized: "drawer.status.unavailable",
                defaultValue: "Not available",
                comment: "Drawer status label when the backend reports a claw is not installable."
            )
        }
        switch claw.installState {
        case .installed:
            return String(localized: "drawer.status.installed")
        case .installedButBlocked:
            return String(localized: "drawer.status.installed")
        case .installing:
            return String(localized: "drawer.status.installing")
        case .uninstalling:
            return String(localized: "drawer.status.uninstalling")
        case .installFailed:
            return String(localized: "drawer.status.failed")
        case .notInstalled:
            return String(localized: "drawer.status.notInstalled")
        case .unknown:
            return String(localized: "drawer.status.unknown")
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

private extension ClawDrawerStatus {
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
