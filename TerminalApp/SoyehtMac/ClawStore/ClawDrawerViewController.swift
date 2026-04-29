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

    func refresh() {
        viewModel.refresh()
    }
}

@MainActor
private final class ClawDrawerViewModel: ObservableObject {
    @Published private(set) var context: ServerContext?
    @Published private(set) var rows: [ClawDrawerRow] = []
    @Published private(set) var catalogClaws: [Claw] = []
    @Published private(set) var isLoading = false
    @Published private(set) var installingClaws: Set<String> = []
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

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ClawDrawerTokens.background)
            .preferredColorScheme(.dark)
            .onAppear { viewModel.refresh() }
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
                    .font(.system(size: 10))
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
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(ClawDrawerTokens.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var theyOSMissingView: some View {
        VStack(spacing: 0) {
            header(title: "// claws")
            Spacer(minLength: 18)
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundColor(ClawDrawerTokens.accent)
                    .frame(width: 52, height: 52)
                    .background(ClawDrawerTokens.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 8) {
                    Text("theyOS not installed")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Install theyOS to manage your claws. Choose an option below:")
                        .font(.system(size: 12))
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
                        .font(.system(size: 24))
                        .foregroundColor(ClawDrawerTokens.textMuted)
                    Text("No claws found")
                        .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: 10))
                    .foregroundColor(ClawDrawerTokens.warning)
                    .lineLimit(3)
                    .padding(12)
            }
        }
    }

    private var installMacView: some View {
        VStack(spacing: 0) {
            header(title: "activate theyOS", showsBack: true)
            LocalInstallView(onPaired: handlePaired, compact: true)
        }
    }

    private var connectServerView: some View {
        VStack(spacing: 0) {
            header(title: "connect server", showsBack: true)
            RemoteConnectView(onPaired: handlePaired, compact: true)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(ClawDrawerTokens.accent)
                .scaleEffect(0.8)
            Text("loading")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ClawDrawerTokens.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyRowsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 24))
                .foregroundColor(ClawDrawerTokens.textMuted)
            Text(viewModel.errorMessage ?? "No claws running")
                .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            iconButton(systemName: "server.rack", action: onShowConnectedServers)
                .help("Connected Servers")
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundColor(ClawDrawerTokens.textMuted)
        }
        .buttonStyle(.plain)
    }

    private func searchField(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ClawDrawerTokens.textMuted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
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
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.black)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(ClawDrawerTokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.badge)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(ClawDrawerTokens.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(ClawDrawerTokens.panel.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ClawDrawerTokens.stroke.opacity(0.65), lineWidth: 1)
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(claw.description)
                        .font(.system(size: 10))
                        .foregroundColor(ClawDrawerTokens.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text("[\(claw.language)]")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ClawDrawerTokens.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            HStack(spacing: 8) {
                Text(stateLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(stateColor)
                Spacer()
                if canInstall {
                    Button(action: onInstall) {
                        Text(isInstalling ? "installing" : "install")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black)
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
        .background(ClawDrawerTokens.panel.opacity(0.85))
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
}

private enum ClawDrawerTokens {
    static let background = Color(red: Double(0x1A) / 255.0, green: Double(0x1C) / 255.0, blue: Double(0x25) / 255.0)
    static let panel = Color(red: Double(0x25) / 255.0, green: Double(0x27) / 255.0, blue: Double(0x31) / 255.0)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: Double(0x10) / 255.0, green: Double(0xB9) / 255.0, blue: Double(0x81) / 255.0)
    static let warning = Color(red: Double(0xF5) / 255.0, green: Double(0x9E) / 255.0, blue: Double(0x0B) / 255.0)
    static let textMuted = Color(red: Double(0x9C) / 255.0, green: Double(0xA3) / 255.0, blue: Double(0xAF) / 255.0)
}
