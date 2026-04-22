import SwiftUI
import SoyehtCore

// MARK: - Instance Entry
//
// Binds an instance to the paired server that owns it so every downstream
// consumer (list row, context menu action, session sheet, terminal attach)
// has a routing context without reading `SessionStore.activeServerId`.
// The `id` is `server.id:instance.id` so two servers emitting the same
// instance id coexist as distinct rows.
struct InstanceEntry: Identifiable {
    let server: PairedServer
    let instance: SoyehtInstance

    var id: String { "\(server.id):\(instance.id)" }
}

// MARK: - Instance List View

struct InstanceListView: View {
    let onConnect: (String, SoyehtInstance, String, ServerContext) -> Void // (wsUrl, instance, sessionName, context)
    let onAddInstance: () -> Void
    let onLogout: () -> Void
    /// New in Fase 2. Called when user taps a pane inside a paired Mac detail
    /// view. Caller is expected to open the terminal pointing at the Mac's
    /// pane attach endpoint.
    var onAttachMacPane: ((_ macID: UUID, _ pane: PaneEntry) -> Void)? = nil
    @Binding var autoSelectInstance: SoyehtInstance?
    @Binding var autoSelectServerId: String?
    @Binding var autoSelectSessionName: String?

    @State private var pendingSessionName: String?
    // Every paired server's claws are fanned out into a single flat list.
    // `InstanceEntry` carries the owning server, so no side-map keyed by
    // instance.id is needed (and two servers with the same instance id
    // render as distinct rows because `InstanceEntry.id` is compound).
    @State private var entries: [InstanceEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedEntry: InstanceEntry?
    @State private var instanceActionError: String?
    @State private var confirmDelete: InstanceEntry?
    @State private var showServerList = false
    // Context under which the Claw Store navigation branch operates. Captured
    // when the user taps the store button so install/uninstall calls route
    // consistently even if `activeServerId` changes mid-flow.
    @State private var clawStoreContext: ServerContext?

    // Observe the shared deploy monitor so the list can render an in-app
    // banner whenever there are deploys in flight. The monitor is a process-
    // wide singleton populated by ClawSetupViewModel.deploy() after a
    // successful create, and it clears itself when polling reaches a terminal
    // state. When activeDeploys is non-empty we also poll the backend list
    // every 3s so a provisioning card appears without manual refresh.
    @ObservedObject private var deployMonitor = ClawDeployMonitor.shared
    @State private var refreshTask: Task<Void, Never>?

    private let apiClient = SoyehtAPIClient.shared
    private let store = SessionStore.shared

    private var onlineCount: Int { entries.filter { $0.instance.isOnline }.count }
    private var offlineCount: Int { entries.filter { !$0.instance.isOnline }.count }

    @State private var clawPath = NavigationPath()

    // Fase 2: paired Macs live alongside claws.
    @ObservedObject private var macRegistry = PairedMacRegistry.shared
    @ObservedObject private var macsStoreBox = PairedMacsStoreObservable.shared
    @State private var selectedMac: PairedMac?

    private var serverCount: Int { store.pairedServers.count }

    var body: some View {
        NavigationStack(path: $clawPath) {
            ZStack {
                SoyehtTheme.bgPrimary.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack {
                        HStack(spacing: 0) {
                            Text(verbatim: "> ")
                                .foregroundColor(SoyehtTheme.accentGreen)
                            Text(verbatim: "soyeht")
                                .foregroundColor(SoyehtTheme.textPrimary)
                        }
                        .font(Typography.monoPageTitle)

                        Spacer()

                        HStack(spacing: 12) {
                            Button(action: onAddInstance) {
                                Image(systemName: "qrcode")
                                    .font(Typography.sansSection)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                            }
                            Button(action: onLogout) {
                                Image(systemName: "person.2")
                                    .font(Typography.sansSection)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)

                    // Persistent deploy banner — one row per in-progress deploy.
                    // Observes ClawDeployMonitor.shared so the user has continuous
                    // feedback after the setup form is dismissed.
                    if !deployMonitor.activeDeploys.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(deployMonitor.activeDeploys) { deploy in
                                DeployBanner(deploy: deploy)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier(AccessibilityID.InstanceList.deployBanner)
                    }

                    // Section label
                    Text("instancelist.section.claws")
                        .font(Typography.monoLabel)
                        .foregroundColor(SoyehtTheme.textComment)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                    if isLoading {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                ProgressView().tint(SoyehtTheme.accentGreen)
                                Text("instancelist.claws.loading")
                                    .font(Typography.monoSmall)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                            }
                            Spacer()
                        }
                        .accessibilityIdentifier(AccessibilityID.InstanceList.loadingState)
                        Spacer()
                    } else if let error = errorMessage {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                Text(verbatim: "[!] \(error)")
                                    .font(Typography.monoSmall)
                                    .foregroundColor(SoyehtTheme.textWarning)
                                    .multilineTextAlignment(.center)
                                Button("retry") { Task { await loadInstances() } }
                                    .font(Typography.monoLabel)
                                    .foregroundColor(SoyehtTheme.accentGreen)
                            }
                            .padding(.horizontal, 20)
                            Spacer()
                        }
                        .accessibilityIdentifier(AccessibilityID.InstanceList.errorState)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                // Fase 2: paired Macs appear at the top.
                                ForEach(macsStoreBox.macs) { mac in
                                    Button {
                                        selectedMac = mac
                                    } label: {
                                        MacHomeRow(mac: mac, client: macRegistry.client(for: mac.macID))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                ForEach(entries) { entry in
                                    let instance = entry.instance
                                    Button {
                                        guard instance.isOnline else { return }
                                        selectedEntry = entry
                                    } label: {
                                        InstanceCard(instance: instance, serverName: entry.server.name)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!instance.isOnline)
                                    .accessibilityIdentifier(AccessibilityID.InstanceList.instanceCard(instance.id))
                                    .contextMenu {
                                        if instance.isOnline {
                                            Button { Task { await performInstanceAction(entry, action: .stop) } } label: {
                                                Label("instancelist.action.stop", systemImage: "stop.circle")
                                            }
                                            Button { Task { await performInstanceAction(entry, action: .restart) } } label: {
                                                Label("instancelist.action.restart", systemImage: "arrow.clockwise.circle")
                                            }
                                            Button { Task { await performInstanceAction(entry, action: .rebuild) } } label: {
                                                Label("instancelist.action.rebuild", systemImage: "arrow.triangle.2.circlepath")
                                            }
                                        } else if !instance.isProvisioning {
                                            // Only offer "start" for stopped instances — a provisioning
                                            // instance has no meaningful action yet (the create job is
                                            // running in the background). Delete stays available below.
                                            Button { Task { await performInstanceAction(entry, action: .restart) } } label: {
                                                Label("instancelist.action.start", systemImage: "play.circle")
                                            }
                                        }
                                        Divider()
                                        Button(role: .destructive) { confirmDelete = entry } label: {
                                            Label("instancelist.action.delete", systemImage: "trash")
                                        }
                                    }
                                }

                                // Claw Store button
                                Button(action: {
                                    // Resolve context at tap time from the active server
                                    // (UX preference), falling back to the first paired.
                                    // The resolved context travels with the whole store
                                    // navigation branch via @State; no routing reads of
                                    // activeServerId happen further down.
                                    let candidateId = store.activeServerId
                                        ?? store.pairedServers.first?.id
                                    if let id = candidateId,
                                       let ctx = store.context(for: id) {
                                        clawStoreContext = ctx
                                        clawPath.append(ClawRoute.store)
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "storefront")
                                            .font(Typography.monoBody)
                                            .foregroundColor(SoyehtTheme.historyGreen)
                                        Text("instancelist.button.clawStore")
                                            .font(Typography.monoCardTitle)
                                            .foregroundColor(SoyehtTheme.historyGreen)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .overlay(
                                        Rectangle()
                                            .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.InstanceList.clawStoreButton)
                            }
                            .padding(.horizontal, 20)
                        }
                        .refreshable { await loadInstances() }

                        Spacer(minLength: 0)

                        // Server row — tap to manage servers
                        Button(action: { showServerList = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "externaldrive")
                                    .font(Typography.monoBody)
                                    .foregroundColor(SoyehtTheme.textComment)
                                Text(LocalizedStringResource(
                                    "instancelist.footer.serversConnected",
                                    defaultValue: "\(serverCount) servers connected",
                                    comment: "InstanceList footer — count of paired servers. %lld = server count. Plural needed."
                                ))
                                    .font(Typography.monoLabelRegular)
                                    .foregroundColor(SoyehtTheme.textPrimary)
                                Circle()
                                    .fill(SoyehtTheme.historyGreen)
                                    .frame(width: 6, height: 6)
                                Spacer()
                                Text(verbatim: ">>")
                                    .font(Typography.monoLabelRegular)
                                    .foregroundColor(SoyehtTheme.textComment)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(hex: "#0A0A0A"))
                            .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.InstanceList.serversButton)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: ClawRoute.self) { route in
                if let ctx = clawStoreContext {
                    switch route {
                    case .store:
                        ClawStoreView(context: ctx)
                    case .detail(let claw):
                        ClawDetailView(claw: claw, context: ctx)
                    case .setup(let claw):
                        ClawSetupView(claw: claw)
                    }
                } else {
                    // Defensive: no paired server available, nothing to render.
                    // The store button disables this case at tap time; this
                    // branch is unreachable during normal flow.
                    EmptyView()
                }
            }
        }
        .task {
            // Auto-select immediately (sheet opens without waiting for network)
            if let auto = autoSelectInstance,
               let serverId = autoSelectServerId,
               let server = store.pairedServers.first(where: { $0.id == serverId }) {
                pendingSessionName = autoSelectSessionName
                selectedEntry = InstanceEntry(server: server, instance: auto)
                autoSelectInstance = nil
                autoSelectServerId = nil
                autoSelectSessionName = nil
            }
            await loadInstances()
        }
        .sheet(item: $selectedEntry, onDismiss: {
            pendingSessionName = nil
            store.clearNavigationState()
        }) { entry in
            SessionListSheet(
                entry: entry,
                onAttach: { wsUrl, sessionName, context in
                    onConnect(wsUrl, entry.instance, sessionName, context)
                },
                preselectedSession: pendingSessionName
            )
        }
        .onChange(of: selectedEntry?.id) { newId in
            if let entry = selectedEntry, newId != nil {
                store.saveNavigationState(NavigationState(
                    serverId: entry.server.id,
                    instanceId: entry.instance.id,
                    sessionName: nil,
                    savedAt: Date()
                ))
            }
        }
        .alert("error", isPresented: .init(
            get: { instanceActionError != nil },
            set: { if !$0 { instanceActionError = nil } }
        )) {
            Button("ok") { instanceActionError = nil }
        } message: {
            Text(instanceActionError ?? "")
        }
        .alert("delete instance", isPresented: .init(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("cancel", role: .cancel) { confirmDelete = nil }
            Button("delete", role: .destructive) {
                if let entry = confirmDelete {
                    Task { await performInstanceAction(entry, action: .delete) }
                }
                confirmDelete = nil
            }
        } message: {
            Text(LocalizedStringResource(
                "instancelist.alert.delete.message",
                defaultValue: "this will permanently delete \(confirmDelete?.instance.name ?? "this instance"). this cannot be undone.",
                comment: "Confirm body when deleting an instance. %@ = instance name."
            ))
        }
        .sheet(isPresented: $showServerList) {
            ServerListView(onAddServer: {
                showServerList = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onAddInstance()
                }
            })
        }
        .sheet(item: $selectedMac) { mac in
            MacDetailView(
                mac: mac,
                onAttach: { macID, pane in
                    selectedMac = nil
                    onAttachMacPane?(macID, pane)
                },
                onDismiss: { selectedMac = nil }
            )
        }
        .onChange(of: showServerList) { isPresented in
            if !isPresented {
                Task { await loadInstances() }
            }
        }
        // Start/stop a 3s refresh loop whenever there are deploys in
        // flight. This is the only place the list polls automatically —
        // when no deploys are active, the list stays idle and relies on
        // pull-to-refresh or view re-entry.
        .onChange(of: deployMonitor.activeDeploys.count) { newCount in
            if newCount > 0 {
                startListRefreshLoop()
            } else {
                refreshTask?.cancel()
                refreshTask = nil
                // One final refresh so the transitioned instance (now
                // active) replaces the provisioning card cleanly.
                Task { await loadInstances() }
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    // MARK: - Deploy-driven polling

    /// 3s polling loop active only while there are deploys in flight. Cancels
    /// itself when `deployMonitor.activeDeploys` empties. Re-entrant-safe:
    /// bails if a task is already running.
    private func startListRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            while !Task.isCancelled && !deployMonitor.activeDeploys.isEmpty {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await loadInstances()
            }
        }
    }

    // MARK: - Instance Actions

    /// Route the action to whichever server owns the instance via the
    /// `ServerContext` carried on the `InstanceEntry`. Never mutates
    /// `activeServerId` — routing is explicit per call.
    private func performInstanceAction(_ entry: InstanceEntry, action: InstanceAction) async {
        guard let context = store.context(for: entry.server.id) else {
            await MainActor.run {
                instanceActionError = "Missing session for \(entry.server.name)"
            }
            return
        }
        do {
            try await apiClient.instanceAction(id: entry.instance.id, action: action, context: context)
            await loadInstances()
        } catch {
            await MainActor.run {
                instanceActionError = error.localizedDescription
            }
        }
    }

    /// Cold-start: aggregate each paired server's own cache (per-server
    /// keys, self-consistent) and render immediately.
    /// Fresh fetch: fan out across every paired server in parallel, each
    /// using its own `ServerContext`. Results are written back per-server
    /// so the next cold-start is accurate for each one independently.
    private func loadInstances() async {
        isLoading = true
        errorMessage = nil

        let servers = store.pairedServers
        guard !servers.isEmpty else {
            entries = []
            isLoading = false
            return
        }

        // Render cached instances per-server so the list has content
        // immediately, even if one of the servers is unreachable.
        let cached: [InstanceEntry] = servers.flatMap { server in
            store.loadInstances(serverId: server.id).map {
                InstanceEntry(server: server, instance: $0)
            }
        }
        if !cached.isEmpty {
            entries = cached
            isLoading = false
        }

        var aggregated: [InstanceEntry] = []
        var lastError: Error?

        await withTaskGroup(of: (PairedServer, Result<[SoyehtInstance], Error>).self) { group in
            for server in servers {
                guard let context = store.context(for: server.id) else { continue }
                group.addTask {
                    do {
                        let list = try await apiClient.getInstances(context: context)
                        return (server, .success(list))
                    } catch {
                        return (server, .failure(error))
                    }
                }
            }
            for await (server, result) in group {
                switch result {
                case .success(let list):
                    store.saveInstances(list, serverId: server.id)
                    aggregated.append(contentsOf: list.map { InstanceEntry(server: server, instance: $0) })
                case .failure(let err):
                    lastError = err
                    // Keep this server's cached rows so one unreachable
                    // server doesn't drop its claws from the list.
                    aggregated.append(contentsOf:
                        store.loadInstances(serverId: server.id).map {
                            InstanceEntry(server: server, instance: $0)
                        }
                    )
                }
            }
        }

        entries = aggregated
        isLoading = false
        if aggregated.isEmpty, let err = lastError {
            errorMessage = err.localizedDescription
        }
    }
}

// MARK: - Deploy Banner

/// In-app banner rendered above the instance list whenever there is at
/// least one deploy in flight. One banner per deploy. Uses the same
/// accentAmber palette as other transient states (install-but-blocked,
/// uninstalling) so the user reads "something is in progress" consistently
/// across the app.
private struct DeployBanner: View {
    let deploy: ClawDeployMonitor.ActiveDeploy

    private var phaseLabel: String {
        switch deploy.phase {
        case "queuing": return "queuing..."
        case "pulling": return "pulling image..."
        case "starting": return "starting vm..."
        case "ready": return "ready"
        case let other?: return "\(other)..."
        case nil: return "provisioning..."
        }
    }

    private var isTerminalReady: Bool { deploy.status == "active" }

    var body: some View {
        HStack(spacing: 10) {
            if isTerminalReady {
                Image(systemName: "checkmark.circle.fill")
                    .font(Typography.sansBody)
                    .foregroundColor(SoyehtTheme.historyGreen)
                    .frame(width: 16, height: 16)
            } else {
                ProgressView()
                    .tint(SoyehtTheme.accentAmber)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(deploy.clawName)
                    .font(Typography.monoCardMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .lineLimit(1)
                Text(deploy.message ?? phaseLabel)
                    .font(Typography.monoTag)
                    .foregroundColor(isTerminalReady ? SoyehtTheme.historyGreen : SoyehtTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("[\(deploy.clawType)]")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textComment)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(Color(hex: "#15100A"))
                .overlay(Rectangle().stroke(SoyehtTheme.accentAmber.opacity(0.5), lineWidth: 1))
        )
        .accessibilityIdentifier(AccessibilityID.InstanceList.deployBannerRow(deploy.id))
    }
}

// MARK: - Instance Card

private struct InstanceCard: View {
    let instance: SoyehtInstance
    let serverName: String?

    // Human-friendly label for the provisioning phase. Backend sends raw
    // identifiers ("queuing", "pulling", "starting") — we lowercase-display
    // them with a trailing ellipsis for consistency with other app copy.
    private var provisioningPhaseLabel: String {
        switch instance.provisioningPhase {
        case "queuing": return "queuing..."
        case "pulling": return "pulling image..."
        case "starting": return "starting vm..."
        case let other?: return "\(other)..."
        case nil: return "provisioning..."
        }
    }

    // Secondary line for the card. For provisioning instances this carries
    // the current phase so the user has continuous feedback in the list
    // without opening the instance. For ready instances, shows the server
    // the claw is running on (e.g. "theyos") so the user knows which
    // paired host the instance lives on.
    private var secondaryText: String {
        if instance.isProvisioning {
            return instance.provisioningMessage ?? provisioningPhaseLabel
        }
        return serverName ?? instance.displayFqdn
    }

    private var secondaryColor: Color {
        instance.isProvisioning ? SoyehtTheme.accentAmber : SoyehtTheme.textSecondary
    }

    private var statusDotColor: Color {
        if instance.isProvisioning { return SoyehtTheme.accentAmber }
        return instance.isOnline ? SoyehtTheme.statusOnline : SoyehtTheme.statusOffline
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if instance.isProvisioning {
                    ProgressView()
                        .tint(SoyehtTheme.accentAmber)
                        .scaleEffect(0.55)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(instance.name)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text(secondaryText)
                    .font(Typography.monoSmall)
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
            }

            Spacer()

            Text(instance.displayTag)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textSecondary)

            if !instance.isProvisioning {
                Text(verbatim: ">>")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textComment)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(SoyehtTheme.bgCard)
                .overlay(Rectangle().stroke(
                    instance.isProvisioning ? SoyehtTheme.accentAmber.opacity(0.4) : SoyehtTheme.bgCardBorder,
                    lineWidth: 1
                ))
        )
        .opacity(instance.isProvisioning ? 0.9 : (instance.isOnline ? 1.0 : 0.5))
    }
}

// MARK: - Session List Sheet (design node ec3Zq)

private struct SessionListSheet: View {
    let entry: InstanceEntry
    let onAttach: (String, String, ServerContext) -> Void // (wsUrl, sessionName, context)
    var preselectedSession: String? = nil

    private var instance: SoyehtInstance { entry.instance }

    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [SoyehtWorkspace] = []
    @State private var windows: [TmuxWindow] = []
    @State private var selectedWorkspace: SoyehtWorkspace?
    @State private var isLoadingWorkspaces = true
    @State private var isLoadingWindows = false
    @State private var isConnecting = false
    @State private var progressBarOffset: CGFloat = -200
    @State private var isCreating = false
    @State private var isKilling = false
    @State private var errorMessage: String?
    @State private var renameTarget: SoyehtWorkspace?
    @State private var renameText: String = ""
    @State private var showNewSessionAlert = false
    @State private var newSessionName: String = ""
    @State private var windowsTask: Task<Void, Never>?
    @State private var panesByWindow: [Int: [TmuxPane]] = [:]
    @State private var isLoadingPanes = false
    @State private var showNewWindowAlert = false
    @State private var newWindowName: String = ""
    @State private var isCreatingWindow = false
    @State private var windowRenameTarget: TmuxWindow?
    @State private var windowRenameText: String = ""
    @State private var lastWindowError: String?
    @State private var connectingWindowIndex: Int?
    @State private var paneRenameTarget: (pane: TmuxPane, window: TmuxWindow)?
    @State private var paneRenameText: String = ""
    @State private var showPaneRenameAlert = false
    @State private var confirmKillWindow: TmuxWindow?
    @State private var confirmKillPane: (pane: TmuxPane, window: TmuxWindow)?

    private let apiClient = SoyehtAPIClient.shared
    private let store = SessionStore.shared
    private let prefs = TerminalPreferences.shared

    /// Resolved `ServerContext` for every API call inside this sheet.
    /// Recomputed on each access so a just-refreshed token flows through
    /// (token rotation is handled by `SessionStore.saveTokenForServer`).
    private var context: ServerContext? {
        store.context(for: entry.server.id)
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Nav header
                HStack(spacing: 10) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(Typography.sans(size: 12 * Typography.uiScale, weight: .medium))
                            Text(instance.name)
                                .font(Typography.monoBodyLargeMedium)
                        }
                        .foregroundColor(SoyehtTheme.textSecondary)
                    }

                    Circle()
                        .fill(SoyehtTheme.statusOnline)
                        .frame(width: 6, height: 6)

                    Spacer()

                    Text(instance.displayTag)
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)

                if isLoadingWorkspaces {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView().tint(SoyehtTheme.accentGreen)
                            Text("instancelist.sessions.loading")
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textSecondary)
                        }
                        Spacer()
                    }
                    Spacer()
                } else if workspaces.isEmpty, let error = errorMessage {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Text("[!] \(error)")  // i18n-exempt: "[!]" is a technical error prefix marker; error string comes from server/network and is passed through verbatim
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textWarning)
                                .multilineTextAlignment(.center)
                            Button("retry") { Task { await loadWorkspaces() } }
                                .font(Typography.monoLabel)
                                .foregroundColor(SoyehtTheme.accentGreen)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("instancelist.section.tmuxSessions")
                                .font(Typography.monoLabel)
                                .foregroundColor(SoyehtTheme.textComment)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)

                            LazyVStack(spacing: 8) {
                                ForEach(workspaces) { ws in
                                    Button {
                                        selectedWorkspace = ws
                                        Task { await loadWindows(session: ws.sessionName) }
                                    } label: {
                                        WorkspaceCard(workspace: ws, isSelected: selectedWorkspace?.id == ws.id)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            Task { await deleteWorkspace(ws) }
                                        } label: {
                                            Label("instancelist.context.delete", systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            renameText = ws.displayName
                                            renameTarget = ws
                                        } label: {
                                            Label("Rename", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) {
                                            Task { await deleteWorkspace(ws) }
                                        } label: {
                                            Label("instancelist.context.delete", systemImage: "trash")
                                        }
                                    }
                                }

                                Button(action: {
                                    newSessionName = ""
                                    showNewSessionAlert = true
                                }) {
                                    HStack(spacing: 6) {
                                        if isCreating {
                                            ProgressView().tint(SoyehtTheme.accentGreen).scaleEffect(0.7)
                                        }
                                        Text("instancelist.button.newSession")
                                    }
                                    .font(Typography.monoBody)
                                    .foregroundColor(SoyehtTheme.accentGreen)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(
                                        Rectangle()
                                            .stroke(SoyehtTheme.accentGreen.opacity(0.4), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.SessionSheet.createWorkspaceButton)
                                .disabled(isCreating)
                                .padding(.top, 4)
                            }
                            .padding(.horizontal, 20)

                            Text(LocalizedStringResource(
                                "instancelist.sessionSheet.footer.activeSessionsHint",
                                defaultValue: "\(workspaces.count) active sessions  ·  swipe left to delete",
                                comment: "Session sheet footer — active count + delete hint. %lld = session count. Plural needed."
                            ))
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textComment)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)

                            // Divider
                            Rectangle()
                                .fill(SoyehtTheme.bgCardBorder)
                                .frame(height: 1)
                                .padding(.horizontal, 20)

                            // Windows section
                            if let ws = selectedWorkspace ?? workspaces.first {
                                windowsSection(workspace: ws)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 16)
                            }
                        }
                    }

                }

                if let error = errorMessage {
                    Text("[!] \(error)")  // i18n-exempt: "[!]" is a technical error prefix marker
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.textWarning)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Spacer().frame(height: 30)
            }
        }
        .accessibilityIdentifier(AccessibilityID.InstanceList.sessionSheet)
        .task { await loadWorkspaces() }
        .alert("instancelist.alert.renameSession.title", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("instancelist.alert.placeholder.sessionName", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("common.button.cancel", role: .cancel) { renameTarget = nil }
            Button("common.button.rename") {
                guard let ws = renameTarget else { return }
                Task { await performRename(workspace: ws, newName: renameText) }
            }
        } message: {
            Text("instancelist.alert.renameSession.message")
        }
        .alert("instancelist.alert.newSession.title", isPresented: $showNewSessionAlert) {
            TextField("instancelist.alert.placeholder.sessionName", text: $newSessionName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("common.button.cancel", role: .cancel) { }
            Button("common.button.create") {
                Task { await createNewWorkspace(name: newSessionName) }
            }
        } message: {
            Text("instancelist.alert.newSession.message")
        }
        .alert("instancelist.alert.newWindow.title", isPresented: $showNewWindowAlert) {
            TextField("instancelist.alert.placeholder.windowNameOptional", text: $newWindowName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("common.button.cancel", role: .cancel) { }
            Button("common.button.create") {
                Task { await createNewWindow(name: newWindowName) }
            }
        } message: {
            Text("instancelist.alert.newWindow.message")
        }
        .alert("instancelist.alert.renameWindow.title", isPresented: Binding(
            get: { windowRenameTarget != nil },
            set: { if !$0 { windowRenameTarget = nil } }
        )) {
            TextField("instancelist.alert.placeholder.windowName", text: $windowRenameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("common.button.cancel", role: .cancel) { windowRenameTarget = nil }
            Button("common.button.rename") {
                guard let w = windowRenameTarget else { return }
                Task { await performWindowRename(window: w, newName: windowRenameText) }
            }
        } message: {
            Text("instancelist.alert.renameWindow.message")
        }
        .alert("instancelist.alert.cannotCloseWindow.title", isPresented: Binding(
            get: { lastWindowError != nil },
            set: { if !$0 { lastWindowError = nil } }
        )) {
            Button("common.button.ok", role: .cancel) { lastWindowError = nil }
        } message: {
            Text(lastWindowError ?? String(localized: "instancelist.alert.cannotCloseWindow.message.fallback"))
        }
        .alert("instancelist.alert.renamePane.title", isPresented: $showPaneRenameAlert) {
            TextField("instancelist.alert.placeholder.nickname", text: $paneRenameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("common.button.cancel", role: .cancel) { paneRenameTarget = nil }
            Button("common.button.save") { savePaneNickname() }
            Button("common.button.reset", role: .destructive) {
                paneRenameText = ""
                savePaneNickname()
            }
        } message: {
            Text("instancelist.alert.renamePane.message")
        }
        .alert("instancelist.alert.killWindow.title", isPresented: Binding(
            get: { confirmKillWindow != nil },
            set: { if !$0 { confirmKillWindow = nil } }
        )) {
            Button("common.button.cancel", role: .cancel) { confirmKillWindow = nil }
            Button("common.button.kill", role: .destructive) {
                if let w = confirmKillWindow { Task { await killWindow(w) } }
                confirmKillWindow = nil
            }
        } message: {
            Text(LocalizedStringResource(
                "instancelist.alert.killWindow.message",
                defaultValue: "This will close window \"\(confirmKillWindow?.name ?? "")\" and all its panes.",
                comment: "Destructive alert body. %@ = window name."
            ))
        }
        .alert("instancelist.alert.killPane.title", isPresented: Binding(
            get: { confirmKillPane != nil },
            set: { if !$0 { confirmKillPane = nil } }
        )) {
            Button("common.button.cancel", role: .cancel) { confirmKillPane = nil }
            Button("common.button.kill", role: .destructive) {
                if let kp = confirmKillPane { Task { await killPane(kp.pane, in: kp.window) } }
                confirmKillPane = nil
            }
        } message: {
            Text("instancelist.alert.killPane.message")
        }
    }

    @ViewBuilder
    private func windowsSection(workspace: SoyehtWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "instancelist.section.windows",
                defaultValue: "// windows · \(workspace.displayName)",
                comment: "Section header — monospace label scoped to the workspace. %@ = workspace name."
            ))
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)

            if isLoadingWindows {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView().tint(SoyehtTheme.historyGreen)
                        Text("instancelist.windows.loading")
                            .font(Typography.monoSmall)
                            .foregroundColor(SoyehtTheme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 16)
            } else if windows.isEmpty {
                // No tmux session running — offer connect
                Button(action: { Task { await attachToWorkspace() } }) {
                    HStack(spacing: 6) {
                        if connectingWindowIndex == -1 {
                            Text("common.status.connecting")
                                .font(Typography.monoBodyMedium)
                        } else {
                            Text(verbatim: "$")
                                .font(Typography.monoBodyBold)
                            Text("instancelist.workspace.connect")
                                .font(Typography.monoBodySemi)
                        }
                    }
                    .foregroundColor(SoyehtTheme.historyGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Rectangle()
                            .fill(connectingWindowIndex == -1
                                  ? SoyehtTheme.historyGreen.opacity(0.25)
                                  : SoyehtTheme.historyGreenBadge)
                            .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
                    )
                    .overlay(alignment: .top) {
                        if connectingWindowIndex == -1 {
                            ZStack(alignment: .leading) {
                                Rectangle().fill(SoyehtTheme.bgTertiary)
                                Rectangle()
                                    .fill(SoyehtTheme.accentAmber)
                                    .frame(width: 200)
                                    .offset(x: progressBarOffset)
                            }
                            .frame(height: 3)
                            .clipped()
                            .onAppear {
                                progressBarOffset = -200
                                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                                    progressBarOffset = UIScreen.main.bounds.width
                                }
                            }
                        }
                    }
                    .clipShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.InstanceList.connectButton)
                .disabled(connectingWindowIndex != nil)

                Text("instancelist.workspace.noSession")
                    .accessibilityIdentifier(AccessibilityID.InstanceList.emptyState)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textComment)
            } else {
                ForEach(windows) { window in
                    WindowCard(
                        window: window,
                        panes: panesByWindow[window.index] ?? [],
                        paneNicknames: paneNicknamesForWindow(window),
                        isLoadingPanes: isLoadingPanes,
                        isConnecting: connectingWindowIndex == window.index,
                        isAnyConnecting: connectingWindowIndex != nil,
                        onSelect: { Task { await selectAndAttachWindow(window) } },
                        onKill: { confirmKillWindow = window },
                        onRename: {
                            windowRenameText = window.displayName
                            windowRenameTarget = window
                        },
                        onSelectPane: { pane in Task { await selectPaneAndAttach(pane, in: window) } },
                        onSplitPane: { Task { await splitPaneInWindow(window) } },
                        onKillPane: { pane in confirmKillPane = (pane, window) },
                        onRenamePane: { pane in
                            paneRenameText = prefs.paneNickname(
                                container: instance.container,
                                session: (selectedWorkspace ?? workspaces.first)?.sessionName ?? "",
                                window: window.index,
                                paneId: pane.paneId
                            ) ?? ""
                            paneRenameTarget = (pane, window)
                            showPaneRenameAlert = true
                        }
                    )
                    .accessibilityIdentifier(AccessibilityID.SessionSheet.windowCard(window.index))
                }

                Button(action: {
                    newWindowName = ""
                    showNewWindowAlert = true
                }) {
                    HStack(spacing: 6) {
                        if isCreatingWindow {
                            ProgressView().tint(SoyehtTheme.historyGreen).scaleEffect(0.7)
                        }
                        Text("instancelist.button.newWindow")
                    }
                    .font(Typography.monoCardMedium)
                    .foregroundColor(SoyehtTheme.historyGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        Rectangle()
                            .fill(SoyehtTheme.historyGreen.opacity(0.09))
                            .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCreatingWindow)
            }
        }
    }

    // MARK: - API Calls

    private func loadWorkspaces() async {
        isLoadingWorkspaces = true
        errorMessage = nil
        guard let context = context else {
            errorMessage = "Missing session for \(entry.server.name)"
            isLoadingWorkspaces = false
            return
        }
        do {
            workspaces = try await apiClient.listWorkspaces(container: instance.container, context: context)
            isLoadingWorkspaces = false
            let target = workspaces.first(where: { $0.sessionName == preselectedSession })
                ?? workspaces.first
            if let ws = target {
                selectedWorkspace = ws
                await loadWindows(session: ws.sessionName)
            }
        } catch {
            isLoadingWorkspaces = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadWindows(session: String) async {
        windowsTask?.cancel()
        isLoadingWindows = true
        panesByWindow = [:]
        guard let context = context else {
            isLoadingWindows = false
            return
        }
        let task = Task {
            do {
                let result = try await apiClient.listWindows(container: instance.container, session: session, context: context)
                guard !Task.isCancelled else { return }
                windows = result
                isLoadingWindows = false
                await loadPanesForAllWindows(session: session)
            } catch {
                guard !Task.isCancelled else { return }
                windows = []
                isLoadingWindows = false
            }
        }
        windowsTask = task
        await task.value
    }

    private func createNewWorkspace(name: String? = nil) async {
        isCreating = true
        errorMessage = nil
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
        guard let context = context else {
            errorMessage = "Missing session for \(entry.server.name)"
            isCreating = false
            return
        }
        do {
            let newWs = try await apiClient.createNewWorkspace(container: instance.container, name: finalName, context: context)
            workspaces.append(newWs)
            selectedWorkspace = newWs
            await loadWindows(session: newWs.sessionName)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }

    private func deleteWorkspace(_ ws: SoyehtWorkspace) async {
        errorMessage = nil
        guard let context = context else {
            errorMessage = "Missing session for \(entry.server.name)"
            return
        }
        do {
            try await apiClient.deleteWorkspace(container: instance.container, workspaceId: ws.id, context: context)
            workspaces.removeAll { $0.id == ws.id }
            if selectedWorkspace?.id == ws.id {
                selectedWorkspace = workspaces.first
                if let first = workspaces.first {
                    await loadWindows(session: first.sessionName)
                } else {
                    windows = []
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            // Reconcile: the delete may have succeeded before network dropped
            if let refreshed = try? await apiClient.listWorkspaces(container: instance.container, context: context) {
                workspaces = refreshed
                if selectedWorkspace.map({ ws in !refreshed.contains { $0.id == ws.id } }) ?? false {
                    selectedWorkspace = workspaces.first
                }
            }
        }
    }

    private func performRename(workspace: SoyehtWorkspace, newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        guard let context = context else {
            errorMessage = "Missing session for \(entry.server.name)"
            return
        }
        do {
            try await apiClient.renameWorkspace(container: instance.container, workspaceId: workspace.id, newName: trimmed, context: context)
            // Reload workspaces to reflect the new name
            workspaces = try await apiClient.listWorkspaces(container: instance.container, context: context)
            selectedWorkspace = workspaces.first { $0.id == workspace.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func killSelectedWorkspace() async {
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        isKilling = true
        errorMessage = nil
        guard let context = context else {
            errorMessage = "Missing session for \(entry.server.name)"
            isKilling = false
            return
        }
        do {
            try await apiClient.deleteWorkspace(container: instance.container, workspaceId: ws.id, context: context)
            workspaces.removeAll { $0.id == ws.id }
            selectedWorkspace = workspaces.first
            if let first = workspaces.first {
                await loadWindows(session: first.sessionName)
            } else {
                windows = []
            }
        } catch {
            errorMessage = error.localizedDescription
            // Reconcile: the delete may have succeeded before network dropped
            if let refreshed = try? await apiClient.listWorkspaces(container: instance.container, context: context) {
                workspaces = refreshed
                selectedWorkspace = workspaces.first
                if let first = workspaces.first {
                    await loadWindows(session: first.sessionName)
                } else {
                    windows = []
                }
            }
        }
        isKilling = false
    }

    // MARK: - Window CRUD

    private func loadPanesForAllWindows(session: String) async {
        isLoadingPanes = true
        guard let context = context else { isLoadingPanes = false; return }
        await withTaskGroup(of: (Int, [TmuxPane]).self) { group in
            for window in windows {
                group.addTask {
                    let panes = (try? await apiClient.listPanes(
                        container: instance.container,
                        session: session,
                        windowIndex: window.index,
                        context: context
                    )) ?? []
                    return (window.index, panes)
                }
            }
            for await (index, panes) in group {
                panesByWindow[index] = panes
            }
        }
        isLoadingPanes = false
    }

    private func selectAndAttachWindow(_ window: TmuxWindow) async {
        guard let ws = selectedWorkspace ?? workspaces.first,
              let context = context else { return }
        connectingWindowIndex = window.index
        do {
            try await apiClient.selectWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                context: context
            )
        } catch {
            connectingWindowIndex = nil
            errorMessage = error.localizedDescription
            return
        }
        await attachToWorkspace()
        connectingWindowIndex = nil
    }

    private func killWindow(_ window: TmuxWindow) async {
        guard let ws = selectedWorkspace ?? workspaces.first,
              let context = context else { return }
        errorMessage = nil
        do {
            try await apiClient.killWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                context: context
            )
            windows.removeAll { $0.index == window.index }
            panesByWindow.removeValue(forKey: window.index)
            await loadWorkspaces()
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(400, let body) = error {
                lastWindowError = body?.error ?? "Cannot close the last window in a session."
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createNewWindow(name: String?) async {
        guard let ws = selectedWorkspace ?? workspaces.first,
              let context = context else { return }
        isCreatingWindow = true
        errorMessage = nil
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            let newWindow = try await apiClient.createWindow(
                container: instance.container,
                session: ws.sessionName,
                name: finalName,
                context: context
            )
            windows.append(newWindow)
            // Fetch panes for the new window
            let panes = (try? await apiClient.listPanes(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: newWindow.index,
                context: context
            )) ?? []
            panesByWindow[newWindow.index] = panes
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreatingWindow = false
    }

    private func performWindowRename(window: TmuxWindow, newName: String) async {
        guard let ws = selectedWorkspace ?? workspaces.first,
              let context = context else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await apiClient.renameWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                name: trimmed,
                context: context
            )
            // Reload windows to get updated names
            await loadWindows(session: ws.sessionName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pane Actions

    private func selectPaneAndAttach(_ pane: TmuxPane, in window: TmuxWindow) async {
        guard let ws = selectedWorkspace ?? workspaces.first,
              let context = context else { return }
        connectingWindowIndex = window.index
        do {
            try await apiClient.selectWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                context: context
            )
            try await apiClient.selectPane(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                paneIndex: pane.index,
                context: context
            )
        } catch {
            connectingWindowIndex = nil
            errorMessage = error.localizedDescription
            return
        }
        await attachToWorkspace()
        connectingWindowIndex = nil
    }

    private func splitPaneInWindow(_ window: TmuxWindow) async {
        guard let ws = selectedWorkspace ?? workspaces.first,
              let context = context else { return }
        do {
            // Select last pane so split always appends at the end
            if let lastPane = (panesByWindow[window.index] ?? []).max(by: { $0.index < $1.index }) {
                try await apiClient.selectPane(
                    container: instance.container,
                    session: ws.sessionName,
                    windowIndex: window.index,
                    paneIndex: lastPane.index,
                    context: context
                )
            }
            try await apiClient.splitPane(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                context: context
            )
            let panes = (try? await apiClient.listPanes(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                context: context
            )) ?? []
            panesByWindow[window.index] = panes
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func killPane(_ pane: TmuxPane, in window: TmuxWindow) async {
        guard let ws = selectedWorkspace ?? workspaces.first,
              let context = context else { return }
        do {
            try await apiClient.killPane(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                paneIndex: pane.index,
                context: context
            )
            // Clean up nickname for the killed pane
            prefs.setPaneNickname(nil, container: instance.container, session: ws.sessionName, window: window.index, paneId: pane.paneId)
            let panes = (try? await apiClient.listPanes(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                context: context
            )) ?? []
            panesByWindow[window.index] = panes
            // If killing the pane also killed the window, reload windows
            if panes.isEmpty {
                await loadWindows(session: ws.sessionName)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func paneNicknamesForWindow(_ window: TmuxWindow) -> [Int: String] {
        guard let ws = selectedWorkspace ?? workspaces.first else { return [:] }
        let panes = panesByWindow[window.index] ?? []
        var result: [Int: String] = [:]
        for pane in panes {
            if let nick = prefs.paneNickname(
                container: instance.container,
                session: ws.sessionName,
                window: window.index,
                paneId: pane.paneId
            ) {
                result[pane.paneId] = nick
            }
        }
        return result
    }

    private func savePaneNickname() {
        guard let target = paneRenameTarget,
              let ws = selectedWorkspace ?? workspaces.first else { return }
        let trimmed = paneRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.setPaneNickname(
            trimmed.isEmpty ? nil : trimmed,
            container: instance.container,
            session: ws.sessionName,
            window: target.window.index,
            paneId: target.pane.paneId
        )
        paneRenameTarget = nil
    }

    private func attachToWorkspace() async {
        let target = selectedWorkspace ?? workspaces.first
        if connectingWindowIndex == nil { connectingWindowIndex = -1 }
        withAnimation(.easeInOut(duration: 0.3)) { isConnecting = true }
        errorMessage = nil

        guard let context = context else {
            errorMessage = "Missing session for \(entry.server.name)"
            connectingWindowIndex = nil
            withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
            progressBarOffset = -200
            return
        }

        if let sessionName = target?.sessionName {
            let wsUrl = apiClient.buildWebSocketURL(
                container: instance.container,
                sessionId: sessionName,
                context: context
            )

            guard let wsURL = URL(string: wsUrl) else {
                errorMessage = "Invalid WebSocket URL"
                connectingWindowIndex = nil
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                return
            }

            let result = await WebSocketTerminalView.verifyHandshake(url: wsURL, timeout: 10)
            switch result {
            case .success:
                connectingWindowIndex = nil
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                onAttach(wsUrl, sessionName, context)
            case .failure(let error):
                connectingWindowIndex = nil
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                errorMessage = error.localizedDescription
            }
        } else {
            do {
                let workspace = try await apiClient.createWorkspace(
                    container: instance.container,
                    context: context
                )
                let sessionName = workspace.workspace.sessionId
                let wsUrl = apiClient.buildWebSocketURL(
                    container: instance.container,
                    sessionId: sessionName,
                    context: context
                )

                guard let wsURL = URL(string: wsUrl) else {
                    errorMessage = "Invalid WebSocket URL"
                    connectingWindowIndex = nil
                    withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                    progressBarOffset = -200
                    return
                }

                let result = await WebSocketTerminalView.verifyHandshake(url: wsURL, timeout: 10)
                switch result {
                case .success:
                    connectingWindowIndex = nil
                    withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                    progressBarOffset = -200
                    onAttach(wsUrl, sessionName, context)
                case .failure(let error):
                    connectingWindowIndex = nil
                    withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                    progressBarOffset = -200
                    errorMessage = error.localizedDescription
                }
            } catch {
                connectingWindowIndex = nil
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Workspace Card

private struct WorkspaceCard: View {
    let workspace: SoyehtWorkspace
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "$")
                .font(Typography.monoBodyBold)
                .foregroundColor(SoyehtTheme.accentGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.displayName)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text(LocalizedStringResource(
                    "instancelist.workspace.windowsAndCreated",
                    defaultValue: "\(workspace.displayWindowCount) windows  ·  created \(workspace.displayCreated)",
                    comment: "Workspace row subtitle. %1$lld = window count (plural needed), %2$@ = relative time label (e.g. '5m ago')."
                ))
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Spacer()

            if workspace.isAttached {
                Text("instancelist.workspace.attached")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.accentGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(SoyehtTheme.accentGreen.opacity(0.15)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(SoyehtTheme.bgCard)
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? SoyehtTheme.accentGreen.opacity(0.5) : SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Window Card

private struct WindowCard: View {
    let window: TmuxWindow
    let panes: [TmuxPane]
    let paneNicknames: [Int: String]
    let isLoadingPanes: Bool
    let isConnecting: Bool
    let isAnyConnecting: Bool
    let onSelect: () -> Void
    let onKill: () -> Void
    let onRename: () -> Void
    let onSelectPane: (TmuxPane) -> Void
    let onSplitPane: () -> Void
    let onKillPane: (TmuxPane) -> Void
    let onRenamePane: (TmuxPane) -> Void

    @State private var progressBarOffset: CGFloat = -200

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Text("\(window.index):")  // i18n-exempt: numeric window index; ":" is a technical separator
                        .font(Typography.monoCardTitle)
                        .foregroundColor(SoyehtTheme.historyGreen)

                    Text(window.displayName)
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()

                    Text(verbatim: ">>")
                        .font(Typography.monoBody)
                        .foregroundColor(window.active ? SoyehtTheme.historyGreen : SoyehtTheme.textTertiary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(window.active ? SoyehtTheme.historyGreen.opacity(0.15) : SoyehtTheme.bgTertiary)
                .overlay(alignment: .top) {
                    if isConnecting {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(SoyehtTheme.bgTertiary)
                            Rectangle()
                                .fill(SoyehtTheme.accentAmber)
                                .frame(width: 200)
                                .offset(x: progressBarOffset)
                        }
                        .frame(height: 3)
                        .clipped()
                        .onAppear {
                            progressBarOffset = -200
                            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                                progressBarOffset = UIScreen.main.bounds.width
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isAnyConnecting)
            .contextMenu {
                Button { onRename() } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) { onKill() } label: {
                    Label("Kill Window", systemImage: "xmark.circle")
                }
            }

            // Tabs row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if isLoadingPanes && panes.isEmpty {
                        ProgressView().tint(SoyehtTheme.historyGreen).scaleEffect(0.7)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(panes) { pane in
                            Button { onSelectPane(pane) } label: {
                                PaneTab(pane: pane, nickname: paneNicknames[pane.paneId])
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.SessionSheet.paneTab(pane.paneId))
                            .contextMenu {
                                Button { onRenamePane(pane) } label: {
                                    Label("instancelist.context.renameTab", systemImage: "pencil")
                                }
                                Button(role: .destructive) { onKillPane(pane) } label: {
                                    Label("instancelist.context.killPane", systemImage: "xmark.circle")
                                }
                            }

                            if pane.active {
                                Button(action: onSplitPane) {
                                    Text("+")
                                        .font(Typography.monoCardMedium)
                                        .foregroundColor(SoyehtTheme.historyGreen)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 16)
                                        .background(
                                            Rectangle()
                                                .fill(SoyehtTheme.historyGreen.opacity(0.09))
                                                .overlay(Rectangle().stroke(SoyehtTheme.historyGreen.opacity(0.27), lineWidth: 1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
        }
        .background(
            Rectangle()
                .fill(SoyehtTheme.windowCardBg)
                .overlay(Rectangle().stroke(SoyehtTheme.windowCardBorder, lineWidth: 1))
        )
    }
}

// MARK: - Pane Tab

private struct PaneTab: View {
    let pane: TmuxPane
    let nickname: String?

    var displayText: String {
        if let nick = nickname, !nick.isEmpty { return nick }
        return "\(pane.index):\(pane.command)"
    }

    var body: some View {
        HStack(spacing: 6) {
            if pane.active {
                Circle()
                    .fill(SoyehtTheme.historyGreen)
                    .frame(width: 6, height: 6)
            }

            Text(displayText)
                .font(Typography.monoCardBody)
                .foregroundColor(pane.active ? SoyehtTheme.textPrimary : SoyehtTheme.historyGray)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(
            Rectangle()
                .fill(pane.active ? Color(hex: "#1F1F1F") : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(pane.active ? SoyehtTheme.historyGreen : SoyehtTheme.tabInactiveBorder, lineWidth: 1)
                )
        )
    }
}
