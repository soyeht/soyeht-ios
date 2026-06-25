import SwiftUI
import SoyehtCore

/// Root SwiftUI view hosted by `ClawStoreWindowController`. Browses the
/// claw catalog; pushes `MacClawDetailView` on selection. Deliberately
/// simpler than the iOS counterpart — no "editor's pick" / "trending"
/// decoration, just a responsive grid that fits the macOS window and
/// surfaces the core install lifecycle directly.
struct MacClawStoreRootView: View {
    let context: ServerContext
    let target: ClawMachineTarget
    let onOpenTerminal: (String) -> Void
    let onConnectThisMac: () -> Void
    let onShowConnectedServers: () -> Void
    @StateObject private var viewModel: ClawStoreViewModel
    /// P6/A: macOS-native guest-image readiness gate (consumes the shared
    /// SoyehtCore model). Blocks install until the engine reports `.ready` or
    /// has no guest VM (`.notApplicable`).
    @StateObject private var readiness: MacGuestImageReadinessModel
    @State private var path: [ClawRoute] = []

    init(
        context: ServerContext,
        onOpenTerminal: @escaping (String) -> Void = { _ in },
        onConnectThisMac: @escaping () -> Void = {},
        onShowConnectedServers: @escaping () -> Void = {}
    ) {
        let target = ClawMachineTarget.server(context)
        self.context = context
        self.target = target
        self.onOpenTerminal = onOpenTerminal
        self.onConnectThisMac = onConnectThisMac
        self.onShowConnectedServers = onShowConnectedServers
        _viewModel = StateObject(wrappedValue: ClawStoreViewModel(machineTarget: target))
        _readiness = StateObject(wrappedValue: MacGuestImageReadinessModel(server: context.server))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("claw.store.navigationTitle")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        serverStatusPill
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task { await viewModel.loadClaws() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("claw.store.toolbar.reload.help")
                    }
                }
                .navigationDestination(for: ClawRoute.self) { route in
                    switch route {
                    case .store(_):
                        content
                    case .householdStore, .householdDetail:
                        // Mac does not produce household-targeted claw routes
                        // today (see iOS InstanceListView for callers). If a
                        // future change starts emitting these on Mac, fall
                        // through to the catalog rather than invoking the
                        // wrong API target via the server `context`. The Mac
                        // sibling of `ClawDetailView(target: .household)`
                        // should ship before that flip.
                        content
                    case .detail(let claw, _):
                        MacClawDetailView(
                            claw: claw,
                            context: context,
                            target: target,
                            readiness: readiness,
                            onInstallStateChanged: {
                                Task { await viewModel.loadClaws() }
                            },
                            onOpenTerminal: onOpenTerminal
                        )
                    case .setup(let claw, let serverId):
                        MacClawSetupView(claw: claw, serverId: serverId)
                    case .serverPicker:
                        // PR-3: introduced for iOS multi-server selection.
                        // Mac never pushes this route — the Claw Store is
                        // already pinned to its window's `ServerContext` —
                        // but the switch must remain exhaustive. Explicit
                        // `EmptyView()` over `default:` so any future
                        // `ClawRoute` case forces a compile-time decision
                        // here too.
                        EmptyView()
                    }
                }
        }
        .task {
            await viewModel.loadClaws()
        }
        .task {
            await pollReadiness()
        }
        .alert("claw.store.alert.error.title", isPresented: .init(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button("common.button.ok") { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "")
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(MacClawStoreTheme.bgPrimary)
        .preferredColorScheme(MacClawStoreTheme.preferredColorScheme)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.claws.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(MacClawStoreTheme.statusGreen)
                Text("claw.store.loading")
                    .font(MacTypography.Fonts.clawStoreStatus)
                    .foregroundColor(MacClawStoreTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 12) {
                Text(LocalizedStringResource(
                    "claw.store.error.banner",
                    defaultValue: "[!] \(error)",
                    comment: "Banner shown when the claw catalog fails to load. %@ = underlying error (server-supplied)."
                ))
                    .font(MacTypography.Fonts.clawStoreStatus)
                    .foregroundColor(MacClawStoreTheme.textWarning)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("common.button.retry") { Task { await viewModel.loadClaws() } }
                        .buttonStyle(.bordered)
                    Button {
                        onConnectThisMac()
                    } label: {
                        Label {
                            Text(LocalizedStringResource(
                                "claw.store.error.connectThisMac",
                                defaultValue: "Connect This Mac",
                                comment: "Button shown when the macOS Claw Store cannot reach the selected server."
                            ))
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("soyeht.macClawStore.connectThisMac")
                    Button {
                        onShowConnectedServers()
                    } label: {
                        Label {
                            Text(LocalizedStringResource(
                                "claw.store.error.openServers",
                                defaultValue: "Open Servers",
                                comment: "Button shown when the macOS Claw Store cannot reach the selected server."
                            ))
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("soyeht.macClawStore.openServers")
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("soyeht.macClawStore.errorBanner")
        } else if viewModel.claws.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(MacTypography.Fonts.clawStoreEmptyIcon)
                    .foregroundColor(MacClawStoreTheme.textMuted)
                Text("claw.store.empty.title")
                    .font(MacTypography.Fonts.clawStoreEmptyTitle)
                    .foregroundColor(MacClawStoreTheme.textSecondary)
                Text("claw.store.empty.description")
                    .font(MacTypography.Fonts.clawStoreStatus)
                    .foregroundColor(MacClawStoreTheme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("soyeht.macClawStore.emptyState")
        } else {
            grid
                .accessibilityIdentifier("soyeht.macClawStore.grid")
        }
    }

    private var serverStatusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(serverStatus.color)
                .frame(width: 7, height: 7)
            Text(verbatim: context.server.displayName)
                .font(MacTypography.Fonts.clawDetailMeta)
                .foregroundColor(MacClawStoreTheme.textPrimary)
                .lineLimit(1)
            Text(serverStatus.label)
                .font(MacTypography.Fonts.clawDetailMeta)
                .foregroundColor(MacClawStoreTheme.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MacClawStoreTheme.bgCard)
        .clipShape(Capsule())
        .accessibilityIdentifier("soyeht.macClawStore.serverStatus")
    }

    private var serverStatus: (label: LocalizedStringResource, color: Color) {
        if viewModel.isLoading && viewModel.claws.isEmpty {
            return (
                LocalizedStringResource(
                    "claw.store.serverStatus.checking",
                    defaultValue: "Checking",
                    comment: "Status label shown while the macOS Claw Store checks the connected server."
                ),
                MacClawStoreTheme.textMuted
            )
        }
        if viewModel.errorMessage != nil {
            return (
                LocalizedStringResource(
                    "claw.store.serverStatus.offline",
                    defaultValue: "Offline",
                    comment: "Status label shown when the macOS Claw Store cannot reach the connected server."
                ),
                MacClawStoreTheme.textWarning
            )
        }
        return (
            LocalizedStringResource(
                "claw.store.serverStatus.online",
                defaultValue: "Online",
                comment: "Status label shown when the macOS Claw Store has loaded from the connected server."
            ),
            MacClawStoreTheme.statusGreen
        )
    }

    private var grid: some View {
        let columns = [
            GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 12, alignment: .top),
        ]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                MacGuestImageRecoveryBanner(
                    state: readiness.state,
                    onCheckAgain: { Task { await readiness.recheck() } },
                    onPrepare: { Task { await readiness.prepare() } },
                    isRechecking: readiness.isRechecking,
                    isPreparing: readiness.isPreparing
                )
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.claws) { claw in
                        MacClawCardView(
                            claw: claw,
                            readiness: readiness.state,
                            onInstall: {
                                // Action-site gate: re-check the readiness-aware
                                // install rule live at tap time so a readiness
                                // change between render and tap cannot let a stale
                                // tap POST an install the gate would block. The
                                // card's `canOfferInstall` governs visibility; this
                                // is the matching action-side guard (parity with
                                // the drawer's `shouldIssueInstall` at the tap).
                                guard MacClawInstallDecision.shouldIssueInstall(
                                    claw: claw,
                                    readiness: readiness.state
                                ) else { return }
                                Task { await viewModel.installClaw(claw) }
                            },
                            onTap: { path.append(ClawRoute.detail(claw, serverId: context.serverId)) }
                        )
                    }
                }
                footer
            }
            .padding(20)
        }
    }

    /// Poll the gate until it resolves to a terminal state (allowed / unavailable).
    /// `.task` cancels this on disappear.
    private func pollReadiness() async {
        while readiness.state.needsFetch, !Task.isCancelled {
            await readiness.refresh()
            guard readiness.state.needsFetch, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("claw.store.header.subtitle")
                .font(MacTypography.Fonts.clawStoreStatus)
                .foregroundColor(MacClawStoreTheme.textMuted)
            if viewModel.isPolling {
                Text("claw.store.header.polling")
                    .font(MacTypography.Fonts.clawStoreFooter)
                    .foregroundColor(MacClawStoreTheme.accentGreen)
            }
        }
    }

    private var footer: some View {
        Text(LocalizedStringResource(
            "claw.store.footer.summary",
            defaultValue: "\(viewModel.availableCount) claws available · \(viewModel.installedCount) installed",
            comment: "Footer summary below the claw grid. %1$lld = available count, %2$lld = installed count."
        ))
            .font(MacTypography.Fonts.clawStoreFooter)
            .foregroundColor(MacClawStoreTheme.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }
}
