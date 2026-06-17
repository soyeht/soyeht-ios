import SwiftUI
import SoyehtCore
import os

private let instanceListLogger = Logger(subsystem: "com.soyeht.mobile", category: "instance-list")

// MARK: - Instance Entry
//
// Binds an instance to the paired server that owns it so every downstream
// consumer (list row, context menu action, session sheet, terminal attach)
// has a routing context without reading `SessionStore.activeServerId`.
// The `id` is `server.id:instance.id` so two servers emitting the same
// instance id coexist as distinct rows.
//
// `server` is the unified `Server` model (Mac or Linux), consumed via
// `ServerRegistry`. The previous `PairedServer` field was a leak of
// the legacy `SessionStore.pairedServers` shape into the view layer
// and forced every section/row to switch on the legacy taxonomy.
struct InstanceEntry: Identifiable {
    let server: Server
    let instance: SoyehtInstance

    var id: String { "\(server.id):\(instance.id)" }
}

private struct InstanceSection: Identifiable {
    let server: Server
    let entries: [InstanceEntry]

    var id: String { server.id }
}

struct HouseholdCreatedInstanceRecord: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let container: String
    let clawType: String?

    init(id: String, name: String, container: String, clawType: String?) {
        self.id = id
        self.name = name
        self.container = container
        self.clawType = clawType
    }

    init(request: CreateInstanceRequest, response: CreateInstanceResponse) {
        self.init(
            id: response.id,
            name: response.name,
            container: response.container,
            clawType: response.clawType ?? request.clawType
        )
    }
}

final class HouseholdCreatedInstancesStore: @unchecked Sendable {
    static let shared = HouseholdCreatedInstancesStore()

    private struct Snapshot: Codable {
        var recordsByServerID: [String: [HouseholdCreatedInstanceRecord]] = [:]
    }

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "com.soyeht.householdCreatedInstances.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func list(serverID: Server.ID) -> [HouseholdCreatedInstanceRecord] {
        lock.withLock {
            snapshot().recordsByServerID[serverID] ?? []
        }
    }

    func upsert(_ record: HouseholdCreatedInstanceRecord, serverID: Server.ID) {
        lock.withLock {
            var snapshot = snapshot()
            var records = snapshot.recordsByServerID[serverID] ?? []
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.append(record)
            }
            snapshot.recordsByServerID[serverID] = records
            save(snapshot)
        }
    }

    func remove(instanceID: String, serverID: Server.ID) {
        lock.withLock {
            var snapshot = snapshot()
            var records = snapshot.recordsByServerID[serverID] ?? []
            records.removeAll { $0.id == instanceID }
            if records.isEmpty {
                snapshot.recordsByServerID.removeValue(forKey: serverID)
            } else {
                snapshot.recordsByServerID[serverID] = records
            }
            save(snapshot)
        }
    }

    func prune(serverID: Server.ID, keeping allowedIDs: Set<String>) {
        lock.withLock {
            var snapshot = snapshot()
            let records = (snapshot.recordsByServerID[serverID] ?? [])
                .filter { allowedIDs.contains($0.id) }
            if records.isEmpty {
                snapshot.recordsByServerID.removeValue(forKey: serverID)
            } else {
                snapshot.recordsByServerID[serverID] = records
            }
            save(snapshot)
        }
    }

    func removeAll(serverID: Server.ID) {
        lock.withLock {
            var snapshot = snapshot()
            snapshot.recordsByServerID.removeValue(forKey: serverID)
            save(snapshot)
        }
    }

    private func snapshot() -> Snapshot {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return decoded
    }

    private func save(_ snapshot: Snapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
struct HouseholdCreatedInstancesLoader {
    typealias Resolver = @MainActor (ClawInstallTarget) -> ClawInstallTargetResolver.Resolution
    typealias ListFetcher = (URL) async throws -> [SoyehtInstance]
    typealias StatusFetcher = (String, URL) async throws -> InstanceStatusResponse

    private let recordStore: HouseholdCreatedInstancesStore
    private let sessionStore: SessionStore
    private let resolver: Resolver
    private let listFetcher: ListFetcher
    private let statusFetcher: StatusFetcher

    init(
        recordStore: HouseholdCreatedInstancesStore = .shared,
        sessionStore: SessionStore = .shared,
        apiClient: SoyehtAPIClient = .shared,
        resolver: @escaping Resolver = { ClawInstallTargetResolver.resolve($0) },
        listFetcher: ListFetcher? = nil,
        statusFetcher: StatusFetcher? = nil
    ) {
        self.recordStore = recordStore
        self.sessionStore = sessionStore
        self.resolver = resolver
        self.listFetcher = listFetcher ?? { endpoint in
            try await apiClient.getInstances(householdEndpoint: endpoint)
        }
        self.statusFetcher = statusFetcher ?? { id, endpoint in
            try await apiClient.getInstanceStatus(
                id: id,
                target: CreateInstanceTarget.householdEndpoint(endpoint)
            )
        }
    }

    func load(for servers: [Server]) async -> [InstanceEntry] {
        var entries: [InstanceEntry] = []
        for server in servers where server.kind == .mac && sessionStore.context(for: server.id) == nil {
            guard case .householdEndpoint(_, let endpoint) = resolver(ClawInstallTarget(serverID: server.id)) else {
                continue
            }

            let records = recordStore.list(serverID: server.id)
            let cachedByID = Dictionary(uniqueKeysWithValues:
                sessionStore.loadInstances(serverId: server.id).map { ($0.id, $0) }
            )
            var instancesByID: [String: SoyehtInstance] = [:]
            var orderedIDs: [String] = []
            var listFailed = false

            func append(_ instance: SoyehtInstance) {
                if instancesByID[instance.id] == nil {
                    orderedIDs.append(instance.id)
                }
                instancesByID[instance.id] = instance
            }

            do {
                let listed = try await listFetcher(endpoint)
                listed.forEach(append)
            } catch {
                listFailed = true
            }

            for record in records {
                if instancesByID[record.id] != nil { continue }
                do {
                    let status = try await statusFetcher(record.id, endpoint)
                    append(Self.instance(from: record, status: status))
                } catch {
                    if Self.isNotFound(error) {
                        recordStore.remove(instanceID: record.id, serverID: server.id)
                    } else if let cached = cachedByID[record.id] {
                        append(cached)
                    }
                }
            }

            if listFailed, records.isEmpty {
                cachedByID.values
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .forEach(append)
            }

            let instances = orderedIDs.compactMap { instancesByID[$0] }
            sessionStore.saveInstances(instances, serverId: server.id)
            entries.append(contentsOf: instances.map { InstanceEntry(server: server, instance: $0) })
        }
        return entries
    }

    private static func instance(
        from record: HouseholdCreatedInstanceRecord,
        status: InstanceStatusResponse
    ) -> SoyehtInstance {
        SoyehtInstance(
            id: record.id,
            name: record.name,
            container: record.container,
            clawType: record.clawType,
            fqdn: nil,
            status: status.status,
            port: nil,
            capabilities: nil,
            provisioningMessage: status.provisioningMessage,
            provisioningPhase: status.provisioningPhase,
            provisioningError: status.provisioningError
        )
    }

    private static func isNotFound(_ error: Error) -> Bool {
        if case SoyehtAPIClient.APIError.httpError(404, _) = error {
            return true
        }
        return false
    }
}

// MARK: - Instance List View

struct InstanceListView: View {
    enum InstanceActionRoute: Equatable {
        case context
        case householdEndpoint
        case unavailable
    }

    private enum InstanceActionTarget {
        case context(ServerContext)
        case householdEndpoint(URL)
    }

    let onConnect: (String, SoyehtInstance, String, ServerContext) -> Void // (wsUrl, instance, sessionName, context)
    let onHouseholdConnect: (URLRequest, SoyehtInstance, String, String, URL) -> Void
    let onAddInstance: () -> Void
    let onLogout: () -> Void
    /// New in Fase 2. Called when user taps a pane inside a paired Mac detail
    /// view. Caller is expected to open the terminal pointing at the Mac's
    /// pane attach endpoint.
    var onAttachMacPane: ((_ macID: UUID, _ pane: PaneEntry) async -> Bool)? = nil
    @Binding var autoSelectInstance: SoyehtInstance?
    @Binding var autoSelectServerId: String?
    @Binding var autoSelectSessionName: String?

    @State private var pendingSessionName: String?
    // Every entry carries its owning server. The UI groups these entries by
    // server so two hosts can both expose `openclaw` without ambiguity.
    @State private var entries: [InstanceEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedEntry: InstanceEntry?
    @State private var instanceActionError: String?
    @State private var confirmDelete: InstanceEntry?
    @State private var showServerList = false

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
    private let householdCreatedInstancesStore = HouseholdCreatedInstancesStore.shared
    @ObservedObject private var identity = SoyehtIdentity.shared
    @Environment(\.scenePhase) private var scenePhase

    private var onlineCount: Int { entries.filter { $0.instance.isOnline }.count }
    private var offlineCount: Int { entries.filter { !$0.instance.isOnline }.count }

    @State private var clawPath = NavigationPath()

    // `ServerRegistry` is the sole source of truth for listing,
    // counting, and ordering paired hosts. `PairedMacRegistry` stays
    // as a per-Mac presence-client cache keyed by `macID: UUID` —
    // a credential/adapter responsibility, not a listing one —
    // because `MacHomeRow` needs a `MacPresenceClient` per Mac and
    // that client's identity is the UUID. The `PairedMac` value
    // itself is fetched on demand via `serverRegistry.pairedMac(for:)`.
    @ObservedObject private var macRegistry = PairedMacRegistry.shared
    @ObservedObject private var serverRegistry = ServerRegistry.shared
    @State private var selectedMac: PairedMac?
    @State private var attachingMacPaneID: String?

    /// Footer "X servers connected" count. Reads from the unified
    /// `ServerRegistry`, which mirrors both legacy stores after every
    /// mutation (see `ServerRegistry.installLegacyMirror`). Counts
    /// every paired entry — Macs AND Linux admin hosts — without
    /// double-counting when the same Mac appears in both legacy stores.
    private var serverCount: Int {
        serverRegistry.count
    }

    /// The mandatory alias sheet can only render for Macs that still
    /// bridge back to the legacy `PairedMac` model. If the registry has
    /// a transient Mac row without that bridge, opening the cover would
    /// present an empty full-screen view.
    private var pendingMacAlias: PairedMac? {
        serverRegistry.macs.lazy.compactMap { server -> PairedMac? in
            guard server.needsAlias else { return nil }
            return serverRegistry.pairedMac(for: server.id)
        }.first
    }

    /// Server-grouped section list driven by `ServerRegistry.servers`
    /// (not `SessionStore.pairedServers`). The previous version
    /// excluded any Mac that arrived through the household-pair flow
    /// because that path writes to `PairedMacsStore` rather than
    /// `pairedServers`; the registry mirror reconciles both into one
    /// stable order, so the section list reflects every paired host.
    private var instanceSections: [InstanceSection] {
        let grouped = Dictionary(grouping: entries, by: { $0.server.id })
        return serverRegistry.servers.compactMap { server in
            let sectionEntries = grouped[server.id] ?? []
            guard !sectionEntries.isEmpty else { return nil }
            return InstanceSection(
                server: server,
                entries: sectionEntries.sorted { lhs, rhs in
                    lhs.instance.name.localizedStandardCompare(rhs.instance.name) == .orderedAscending
                }
            )
        }
    }

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
                                // Apps section: paired Macs that the iPhone
                                // mirrors. Source-of-truth: `ServerRegistry`.
                                // Each entry comes from there as a `Server`
                                // with kind `.mac`; the row still needs a
                                // `PairedMac` (for `MacPresenceClient` keyed
                                // by UUID `macID`), so we look it up via
                                // `registry.pairedMac(for:)` which performs
                                // the legacy-store lookup behind the facade.
                                // Macs in the registry but missing from
                                // `PairedMacsStore` (rare — only when a
                                // QR-server flow surfaced a Mac before the
                                // household-machine path mirrored it) are
                                // skipped to keep presence + secret
                                // semantics consistent. Header + typography
                                // match `// claws` below.
                                let macRows: [(server: Server, paired: PairedMac)] = serverRegistry.macs.compactMap { server in
                                    guard let paired = serverRegistry.pairedMac(for: server.id) else { return nil }
                                    return (server, paired)
                                }
                                if !macRows.isEmpty {
                                    Text("instancelist.section.apps")
                                        .font(Typography.monoLabel)
                                        .foregroundColor(SoyehtTheme.textComment)
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityIdentifier(AccessibilityID.InstanceList.appsSectionHeader)
                                }
                                ForEach(macRows, id: \.server.id) { entry in
                                    Button {
                                        selectedMac = entry.paired
                                    } label: {
                                        MacHomeRow(
                                            mac: entry.paired,
                                            client: macRegistry.client(for: entry.paired.macID)
                                        )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.InstanceList.macCard(entry.server.id))
                                }
                                // Claws section header — always rendered so
                                // the page hierarchy stays consistent even
                                // when no instances exist yet (matches the
                                // original behaviour of the now-removed
                                // standalone block).
                                Text("instancelist.section.claws")
                                    .font(Typography.monoLabel)
                                    .foregroundColor(SoyehtTheme.textComment)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(instanceSections) { section in
                                    ServerSectionHeader(
                                        server: section.server,
                                        count: section.entries.count
                                    )
                                        .accessibilityIdentifier(AccessibilityID.InstanceList.serverSection(section.server.id))

                                    ForEach(section.entries) { entry in
                                        instanceRow(for: entry)
                                    }
                                }

                                // Claw Store button — PR-3.
                                //
                                // Cardinality decides the destination:
                                //
                                //   • 0 servers — should never reach here
                                //     because the button is hidden by
                                //     the surrounding `.if serverCount > 0`
                                //     gate. Render `.serverPicker` if it
                                //     does for any reason (the picker
                                //     itself surfaces an empty state).
                                //   • 1 server — push `.store(serverId:)`
                                //     directly. The resolver decides the
                                //     wire path (`.server` or selected-Mac
                                //     household endpoint) at the next hop.
                                //   • >= 2 servers — push `.serverPicker`.
                                //     The user picks before the catalog
                                //     opens so install/deploy are bound
                                //     to a known server.
                                Button(action: {
                                    guard SoyehtFeatureFlags.clawStoreEnabled else {
                                        openClawStoreComingSoon()
                                        return
                                    }
                                    let servers = serverRegistry.servers
                                    if servers.count == 1 {
                                        openClawStore(serverId: servers[0].id)
                                    } else {
                                        clawPath.append(ClawRoute.serverPicker)
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
                            .background(SoyehtTheme.bgPrimary)
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
                switch route {
                case .store(let serverId):
                    // PR-3: ClawStoreView speaks ClawInstallTarget. The
                    // resolver decides at its own boundary whether the
                    // route is workable; the View renders the right
                    // placeholder for each resolution. We no longer
                    // pre-check `store.context(for:)` here — that would
                    // duplicate the resolver's logic and miss the
                    // selected-Mac household endpoint path.
                    if SoyehtFeatureFlags.clawStoreEnabled {
                        ClawStoreView(installTarget: ClawInstallTarget(serverID: serverId))
                    } else {
                        ClawStoreComingSoonView(onBack: popClawRoute)
                    }
                case .householdStore:
                    // PR-3: iOS no longer produces `.householdStore`.
                    // The case stays alive for macOS. Render an empty
                    // placeholder if we somehow hit it (e.g. stale
                    // saved navigation state); the user can press back.
                    EmptyView()
                case .detail(let claw, let serverId):
                    if SoyehtFeatureFlags.clawStoreEnabled {
                        ClawDetailView(
                            claw: claw,
                            installTarget: ClawInstallTarget(serverID: serverId)
                        )
                    } else {
                        ClawStoreComingSoonView(onBack: popClawRoute)
                    }
                case .householdDetail:
                    // PR-3: same as `.householdStore`. iOS no longer
                    // produces this case; keep the ramp exhaustive.
                    EmptyView()
                case .setup(let claw, let serverId):
                    if SoyehtFeatureFlags.clawStoreEnabled {
                        ClawSetupView(claw: claw, serverId: serverId)
                    } else {
                        ClawStoreComingSoonView(onBack: popClawRoute)
                    }
                case .serverPicker:
                    if SoyehtFeatureFlags.clawStoreEnabled {
                        ClawStoreServerPickerView(
                            onSelect: { target in
                                // Swap the picker for the catalog by
                                // replacing the top of the stack — Back
                                // from the catalog returns to the home,
                                // not to the picker.
                                clawPath.removeLast()
                                clawPath.append(ClawRoute.store(serverId: target.serverID))
                            },
                            onBack: popClawRoute
                        )
                    } else {
                        ClawStoreComingSoonView(onBack: popClawRoute)
                    }
                }
            }
        }
        .task {
            // Auto-select immediately (sheet opens without waiting for network)
            if let auto = autoSelectInstance,
               let serverId = autoSelectServerId,
               let server = serverRegistry.server(id: serverId) {
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
                onHouseholdAttach: { request, sessionName, endpoint in
                    onHouseholdConnect(request, entry.instance, sessionName, entry.server.id, endpoint)
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
        .alert("common.error.title", isPresented: .init(
            get: { instanceActionError != nil },
            set: { if !$0 { instanceActionError = nil } }
        )) {
            Button("common.button.ok.lower") { instanceActionError = nil }
        } message: {
            Text(instanceActionError ?? "")
        }
        .alert("instancelist.alert.delete.title", isPresented: .init(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("common.button.cancel.lower", role: .cancel) { confirmDelete = nil }
            Button("common.button.delete.lower", role: .destructive) {
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
                attachingPaneID: attachingMacPaneID,
                onAttach: { macID, pane in
                    guard attachingMacPaneID == nil else { return }
                    attachingMacPaneID = pane.id
                    Task {
                        let didAttach = await (onAttachMacPane?(macID, pane) ?? false)
                        await MainActor.run {
                            attachingMacPaneID = nil
                            selectedMac = nil
                            if !didAttach {
                                instanceListLogger.error("soyeht_diag mac_pane_attach_failed pane_id=\(pane.id, privacy: .public)")
                            }
                        }
                    }
                },
                onDismiss: {
                    guard attachingMacPaneID == nil else { return }
                    selectedMac = nil
                }
            )
            .interactiveDismissDisabled(attachingMacPaneID != nil)
        }
        // Mandatory Mac-naming step. The cover is data-driven: it
        // appears as long as any paired Mac still has
        // `needsAlias == true` and auto-dismisses when no unnamed
        // Macs remain. Driven off `serverRegistry.macs` (the unified
        // source) and bridged to the legacy `PairedMac` via
        // `registry.pairedMac(for:)` because `MacAliasView` takes a
        // `PairedMac` for the validator + uniqueness reuse. Single
        // source for the rule: see `Server.needsAlias`.
        .fullScreenCover(isPresented: Binding(
            get: { pendingMacAlias != nil },
            set: { _ in }
        )) {
            if let pending = pendingMacAlias {
                MacAliasView(mac: pending, onNamed: { /* state-driven dismiss */ })
                    .interactiveDismissDisabled()
            }
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
        .task {
            // Best-effort sync of the cached household name with the Mac engine
            // when this screen first appears, so a rename done on the Mac
            // since pairing surfaces without waiting for a background→active
            // transition. The facade silently no-ops if the engine is
            // unreachable or nothing changed.
            await identity.refresh()
        }
        .onChange(of: scenePhase) { phase in
            // ScenePhase-driven invalidation: refresh on each return to
            // foreground (WWDC 2020 "App essentials in SwiftUI" pattern).
            guard phase == .active else { return }
            Task { await identity.refresh() }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    // MARK: - Deploy-driven polling

    private func popClawRoute() {
        guard !clawPath.isEmpty else { return }
        clawPath.removeLast()
    }

    private func openClawStoreComingSoon() {
        clawPath.append(ClawRoute.store(serverId: "__claw-store-coming-soon"))
    }

    private func openClawStore(serverId: String) {
        guard SoyehtFeatureFlags.clawStoreEnabled else {
            openClawStoreComingSoon()
            return
        }
        store.setActiveServer(id: serverId)
        clawPath.append(ClawRoute.store(serverId: serverId))
    }

    // PR-3+: `hasHouseholdSession` and `openHouseholdClawStore` were
    // removed when the iOS Claw Store button stopped routing through
    // the household aggregate. Household Claw wire targets are produced
    // only by `ClawInstallTargetResolver`; `identity` is still observed
    // elsewhere for UI affordances unrelated to Claw routing.

    @ViewBuilder
    private func instanceRow(for entry: InstanceEntry) -> some View {
        let instance = entry.instance
        let terminalUnavailableReason = terminalUnavailableReason(for: entry)
        if terminalUnavailableReason == nil {
            Button {
                guard instance.isOnline else { return }
                selectedEntry = entry
            } label: {
                InstanceCard(
                    instance: instance,
                    serverName: nil,
                    terminalUnavailableReason: nil
                )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!instance.isOnline)
            .accessibilityIdentifier(AccessibilityID.InstanceList.instanceCard(instance.id))
            .contextMenu {
                if instanceActionTarget(for: entry) != nil {
                    instanceActionsMenu(for: entry)
                }
            }
        } else {
            InstanceCard(
                instance: instance,
                serverName: nil,
                terminalUnavailableReason: terminalUnavailableReason
            )
            .accessibilityIdentifier(AccessibilityID.InstanceList.instanceCard(instance.id))
        }
    }

    private func terminalUnavailableReason(for entry: InstanceEntry) -> String? {
        if Self.terminalUnavailableReason(
            serverKind: entry.server.kind,
            hasContext: store.context(for: entry.server.id) != nil,
            hasHouseholdEndpoint: householdEndpoint(for: entry) != nil
        ) == nil {
            return nil
        }
        return Self.terminalUnavailableReason(
            serverKind: entry.server.kind,
            hasContext: store.context(for: entry.server.id) != nil
        )
    }

    static func terminalUnavailableReason(
        serverKind: Server.Kind,
        hasContext: Bool,
        hasHouseholdEndpoint: Bool
    ) -> String? {
        guard serverKind == .mac, !hasContext, !hasHouseholdEndpoint else {
            return nil
        }
        return terminalUnavailableReason(serverKind: serverKind, hasContext: hasContext)
    }

    static func terminalUnavailableReason(serverKind: Server.Kind, hasContext: Bool) -> String? {
        guard serverKind == .mac, !hasContext else {
            return nil
        }
        return String(
            localized: "instancelist.terminalUnavailable.householdMac",
            defaultValue: "terminal unavailable on this Mac yet",
            comment: "Shown on Mac household-created claw cards until household terminal attach exists."
        )
    }

    @MainActor
    private func householdEndpoint(for entry: InstanceEntry) -> URL? {
        guard entry.server.kind == .mac,
              store.context(for: entry.server.id) == nil else {
            return nil
        }
        if case .householdEndpoint(_, let endpoint) = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: entry.server.id)
        ) {
            return endpoint
        }
        return nil
    }

    static func instanceActionRoute(
        serverKind: Server.Kind,
        hasContext: Bool,
        hasHouseholdEndpoint: Bool
    ) -> InstanceActionRoute {
        if hasContext {
            return .context
        }
        if serverKind == .mac, hasHouseholdEndpoint {
            return .householdEndpoint
        }
        return .unavailable
    }

    static func entriesAfterLocalDelete(
        _ entries: [InstanceEntry],
        deleting entry: InstanceEntry
    ) -> [InstanceEntry] {
        entries.filter { $0.id != entry.id }
    }

    static func instancesAfterLocalDelete(
        _ instances: [SoyehtInstance],
        deleting instanceID: String
    ) -> [SoyehtInstance] {
        instances.filter { $0.id != instanceID }
    }

    @MainActor
    private func instanceActionTarget(for entry: InstanceEntry) -> InstanceActionTarget? {
        if let context = store.context(for: entry.server.id) {
            return .context(context)
        }
        if let endpoint = householdEndpoint(for: entry),
           Self.instanceActionRoute(
            serverKind: entry.server.kind,
            hasContext: false,
            hasHouseholdEndpoint: true
           ) == .householdEndpoint {
            return .householdEndpoint(endpoint)
        }
        return nil
    }

    @ViewBuilder
    private func instanceActionsMenu(for entry: InstanceEntry) -> some View {
        let instance = entry.instance
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
            // Only offer "start" for stopped instances; provisioning is already
            // driven by the create job.
            Button { Task { await performInstanceAction(entry, action: .restart) } } label: {
                Label("instancelist.action.start", systemImage: "play.circle")
            }
        }
        Divider()
        Button(role: .destructive) { confirmDelete = entry } label: {
            Label("instancelist.action.delete", systemImage: "trash")
        }
    }

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

    /// Route the action to whichever server owns the instance. Context-backed
    /// Linux/Mac rows keep the legacy `ServerContext` path; Mac household rows
    /// without context use the resolved household endpoint. Never mutates
    /// `activeServerId` — routing is explicit per call.
    @MainActor
    private func performInstanceAction(_ entry: InstanceEntry, action: InstanceAction) async {
        guard let target = instanceActionTarget(for: entry) else {
            instanceActionError = instanceActionsUnavailableMessage(for: entry)
            return
        }
        do {
            switch target {
            case .context(let context):
                try await apiClient.instanceAction(id: entry.instance.id, action: action, context: context)
            case .householdEndpoint(let endpoint):
                try await apiClient.instanceAction(
                    id: entry.instance.id,
                    action: action,
                    householdEndpoint: endpoint
                )
            }
            if action == .delete {
                removeDeletedInstanceLocally(entry)
            }
            await loadInstances()
        } catch {
            instanceActionError = error.localizedDescription
        }
    }

    private func instanceActionsUnavailableMessage(for entry: InstanceEntry) -> String {
        String(
            localized: "instancelist.error.instanceActionsUnavailable",
            defaultValue: "Instance actions are unavailable for \(entry.server.displayName)",
            comment: "Error shown when no context or household endpoint can route an instance action. %@ = server name."
        )
    }

    private func removeDeletedInstanceLocally(_ entry: InstanceEntry) {
        householdCreatedInstancesStore.remove(instanceID: entry.instance.id, serverID: entry.server.id)
        let cached = Self.instancesAfterLocalDelete(
            store.loadInstances(serverId: entry.server.id),
            deleting: entry.instance.id
        )
        store.saveInstances(cached, serverId: entry.server.id)
        entries = Self.entriesAfterLocalDelete(entries, deleting: entry)
    }

    /// Cold-start: aggregate each paired server's own cache (per-server
    /// keys, self-consistent) and render immediately.
    /// Fresh fetch: fan out across every paired server in parallel, each
    /// using its own `ServerContext`. Results are written back per-server
    /// so the next cold-start is accurate for each one independently.
    private func loadInstances() async {
        isLoading = true
        errorMessage = nil

        // Drive the per-server fan-out off the unified registry, not
        // `store.pairedServers`. Per-server credential lookup
        // (`store.context(for:)`) still uses `SessionStore` — that
        // is the credential adapter and is intentionally untouched.
        let servers = serverRegistry.servers
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

        await withTaskGroup(of: (Server, Result<[SoyehtInstance], Error>).self) { group in
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

        let householdEntries = await HouseholdCreatedInstancesLoader(
            recordStore: householdCreatedInstancesStore,
            sessionStore: store,
            apiClient: apiClient
        ).load(for: servers)
        aggregated.append(contentsOf: householdEntries)

        entries = aggregated
        isLoading = false
        if aggregated.isEmpty, let err = lastError {
            errorMessage = err.localizedDescription
        }
    }
}

// MARK: - Claw Store Coming Soon

private struct ClawStoreComingSoonView: View {
    let onBack: () -> Void

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) {
                    Text(verbatim: "<")
                        .font(Typography.monoPageTitle)
                        .foregroundColor(SoyehtTheme.accentGreen)
                }
                Spacer()
                Text("clawStore.comingSoon.title")
                    .font(Typography.monoPageTitle)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            .padding(20)
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Claw Store Missing Session

private struct MissingClawStoreSessionView: View {
    let onBack: () -> Void
    let onManageServers: () -> Void

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Text(verbatim: "<")
                            .font(Typography.monoPageTitle)
                            .foregroundColor(SoyehtTheme.accentGreen)
                    }
                    Text("clawstore.title")
                        .font(Typography.monoPageTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("clawstore.missingSession.title")
                        .font(Typography.monoCardTitle)
                        .foregroundColor(SoyehtTheme.textWarning)
                    Text("clawstore.missingSession.message")
                        .font(Typography.monoLabelRegular)
                        .foregroundColor(SoyehtTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SoyehtTheme.bgCard)
                .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))

                Button(action: onManageServers) {
                    Text("servers")
                        .font(Typography.monoCardTitle)
                        .foregroundColor(SoyehtTheme.buttonTextOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(SoyehtTheme.historyGreen)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .navigationBarHidden(true)
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
        case "queuing":
            return String(localized: "claw.deploy.phase.queuing", defaultValue: "queuing...")
        case "pulling":
            return String(localized: "claw.deploy.phase.pulling", defaultValue: "pulling image...")
        case "starting":
            return String(localized: "claw.deploy.phase.starting", defaultValue: "starting vm...")
        case "ready":
            return String(localized: "claw.deploy.phase.ready", defaultValue: "ready")
        case let other?:
            return String(
                localized: "claw.deploy.phase.other",
                defaultValue: "\(other)...",
                comment: "Fallback deploy phase label. %@ = backend phase name."
            )
        case nil:
            return String(localized: "claw.deploy.phase.provisioning", defaultValue: "provisioning...")
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
                .fill(SoyehtTheme.bgCard)
                .overlay(Rectangle().stroke(SoyehtTheme.accentAmberStrong, lineWidth: 1))
        )
        .accessibilityIdentifier(AccessibilityID.InstanceList.deployBannerRow(deploy.id))
    }
}

// MARK: - Server Section

private struct ServerSectionHeader: View {
    let server: Server
    let count: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.displayName)
                        .font(Typography.monoCardTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .lineLimit(1)

                    InstanceServerPlatformBadge(kind: server.kind)
                }

                Text(server.lastHost ?? server.hostname)
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textComment)
                    .lineLimit(1)
            }

            Spacer()

            Text(verbatim: "\(count)")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SoyehtTheme.bgCard)
                .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct InstanceServerPlatformBadge: View {
    let kind: Server.Kind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(Typography.monoTag)
        }
        .foregroundColor(SoyehtTheme.historyGreen)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(SoyehtTheme.historyGreenBadge)
        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
    }

    private var iconName: String {
        switch kind {
        case .mac: return "desktopcomputer"
        case .linux: return "terminal"
        }
    }

    private var label: String {
        switch kind {
        case .mac: return "macOS"
        case .linux: return "Linux"
        }
    }
}

// MARK: - Instance Card

private struct InstanceCard: View {
    let instance: SoyehtInstance
    let serverName: String?
    let terminalUnavailableReason: String?

    // Human-friendly label for the provisioning phase. Backend sends raw
    // identifiers ("queuing", "pulling", "starting") — we lowercase-display
    // them with a trailing ellipsis for consistency with other app copy.
    private var provisioningPhaseLabel: String {
        switch instance.provisioningPhase {
        case "queuing":
            return String(localized: "claw.deploy.phase.queuing", defaultValue: "queuing...")
        case "pulling":
            return String(localized: "claw.deploy.phase.pulling", defaultValue: "pulling image...")
        case "starting":
            return String(localized: "claw.deploy.phase.starting", defaultValue: "starting vm...")
        case let other?:
            return String(
                localized: "claw.deploy.phase.other",
                defaultValue: "\(other)...",
                comment: "Fallback deploy phase label. %@ = backend phase name."
            )
        case nil:
            return String(localized: "claw.deploy.phase.provisioning", defaultValue: "provisioning...")
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
        if let terminalUnavailableReason {
            return terminalUnavailableReason
        }
        return serverName ?? instance.displayFqdn
    }

    private var secondaryColor: Color {
        if terminalUnavailableReason != nil, !instance.isProvisioning {
            return SoyehtTheme.textWarning
        }
        return instance.isProvisioning ? SoyehtTheme.accentAmber : SoyehtTheme.textSecondary
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

            if !instance.isProvisioning, terminalUnavailableReason == nil {
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
                    instance.isProvisioning ? SoyehtTheme.accentAmberStrong : SoyehtTheme.bgCardBorder,
                    lineWidth: 1
                ))
        )
    }
}

// MARK: - Session List Sheet (design node ec3Zq)

private struct SessionListSheet: View {
    let entry: InstanceEntry
    let onAttach: (String, String, ServerContext) -> Void // (wsUrl, sessionName, context)
    let onHouseholdAttach: (URLRequest, String, URL) -> Void
    var preselectedSession: String? = nil

    private var instance: SoyehtInstance { entry.instance }

    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [SoyehtWorkspace] = []
    @State private var selectedWorkspace: SoyehtWorkspace?
    @State private var isLoadingWorkspaces = true
    @State private var isConnecting = false
    @State private var progressBarOffset: CGFloat = -200
    @State private var isCreating = false
    @State private var isKilling = false
    @State private var errorMessage: String?
    @State private var renameTarget: SoyehtWorkspace?
    @State private var renameText: String = ""
    @State private var showNewSessionAlert = false
    @State private var newSessionName: String = ""
    @State private var connectingWorkspaceId: String?

    private let apiClient = SoyehtAPIClient.shared
    private let store = SessionStore.shared
    private let prefs = TerminalPreferences.shared

    private enum AttachTarget {
        case server(ServerContext)
        case householdEndpoint(URL)
    }

    /// Resolved `ServerContext` for every API call inside this sheet.
    /// Recomputed on each access so a just-refreshed token flows through
    /// (token rotation is handled by `SessionStore.saveTokenForServer`).
    private var context: ServerContext? {
        store.context(for: entry.server.id)
    }

    private var attachTarget: AttachTarget? {
        if let context {
            return .server(context)
        }
        if case .householdEndpoint(_, let endpoint) = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: entry.server.id)
        ) {
            return .householdEndpoint(endpoint)
        }
        return nil
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
                                .font(Typography.iconNav)
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
                            Text("instancelist.section.conversations")
                                .font(Typography.monoLabel)
                                .foregroundColor(SoyehtTheme.textComment)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)

                            LazyVStack(spacing: 8) {
                                ForEach(workspaces) { ws in
                                    Button {
                                        selectedWorkspace = ws
                                        Task { await attachToWorkspace() }
                                    } label: {
                                        WorkspaceCard(workspace: ws, isSelected: selectedWorkspace?.id == ws.id)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(connectingWorkspaceId != nil)
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
                                            Label("common.button.rename", systemImage: "pencil")
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
                                            .stroke(SoyehtTheme.historyGreenStrong, lineWidth: 1)
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
    }

    // MARK: - API Calls

    private func loadWorkspaces() async {
        isLoadingWorkspaces = true
        errorMessage = nil
        guard let target = attachTarget else {
            errorMessage = String(
                localized: "instancelist.error.missingSession",
                defaultValue: "Missing session for \(entry.server.displayName)",
                comment: "Error shown when the app has no saved session for a server. %@ = server name."
            )
            isLoadingWorkspaces = false
            return
        }
        do {
            switch target {
            case .server(let context):
                workspaces = try await apiClient.listWorkspaces(container: instance.container, context: context)
            case .householdEndpoint(let endpoint):
                workspaces = try await apiClient.listWorkspaces(
                    container: instance.container,
                    householdEndpoint: endpoint
                )
            }
            isLoadingWorkspaces = false
            let target = workspaces.first(where: { $0.sessionName == preselectedSession })
                ?? workspaces.first
            if let ws = target {
                selectedWorkspace = ws
            }
        } catch {
            isLoadingWorkspaces = false
            errorMessage = error.localizedDescription
        }
    }

    private func createNewWorkspace(name: String? = nil) async {
        isCreating = true
        errorMessage = nil
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
        guard let target = attachTarget else {
            errorMessage = String(
                localized: "instancelist.error.missingSession",
                defaultValue: "Missing session for \(entry.server.displayName)",
                comment: "Error shown when the app has no saved session for a server. %@ = server name."
            )
            isCreating = false
            return
        }
        do {
            let newWs: SoyehtWorkspace
            switch target {
            case .server(let context):
                newWs = try await apiClient.createNewWorkspace(
                    container: instance.container,
                    name: finalName,
                    context: context
                )
            case .householdEndpoint(let endpoint):
                newWs = try await apiClient.createNewWorkspace(
                    container: instance.container,
                    name: finalName,
                    householdEndpoint: endpoint
                )
            }
            workspaces.append(newWs)
            selectedWorkspace = newWs
            isCreating = false
            await attachToWorkspace()
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }

    private func deleteWorkspace(_ ws: SoyehtWorkspace) async {
        errorMessage = nil
        guard let target = attachTarget else {
            errorMessage = String(
                localized: "instancelist.error.missingSession",
                defaultValue: "Missing session for \(entry.server.displayName)",
                comment: "Error shown when the app has no saved session for a server. %@ = server name."
            )
            return
        }
        do {
            switch target {
            case .server(let context):
                try await apiClient.deleteWorkspace(
                    container: instance.container,
                    workspaceId: ws.id,
                    context: context
                )
            case .householdEndpoint(let endpoint):
                try await apiClient.deleteWorkspace(
                    container: instance.container,
                    workspaceId: ws.id,
                    householdEndpoint: endpoint
                )
            }
            workspaces.removeAll { $0.id == ws.id }
            if selectedWorkspace?.id == ws.id {
                selectedWorkspace = workspaces.first
            }
        } catch {
            errorMessage = error.localizedDescription
            if let refreshed = try? await refreshedWorkspaces(for: target) {
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
        guard let target = attachTarget else {
            errorMessage = String(
                localized: "instancelist.error.missingSession",
                defaultValue: "Missing session for \(entry.server.displayName)",
                comment: "Error shown when the app has no saved session for a server. %@ = server name."
            )
            return
        }
        do {
            switch target {
            case .server(let context):
                try await apiClient.renameWorkspace(
                    container: instance.container,
                    workspaceId: workspace.id,
                    newName: trimmed,
                    context: context
                )
            case .householdEndpoint(let endpoint):
                try await apiClient.renameWorkspace(
                    container: instance.container,
                    workspaceId: workspace.id,
                    newName: trimmed,
                    householdEndpoint: endpoint
                )
            }
            workspaces = try await refreshedWorkspaces(for: target)
            selectedWorkspace = workspaces.first { $0.id == workspace.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func attachToWorkspace() async {
        let target = selectedWorkspace ?? workspaces.first
        connectingWorkspaceId = target?.id
        withAnimation(.easeInOut(duration: 0.3)) { isConnecting = true }
        errorMessage = nil

        guard let attachTarget = attachTarget else {
            errorMessage = String(
                localized: "instancelist.error.missingSession",
                defaultValue: "Missing session for \(entry.server.displayName)",
                comment: "Error shown when the app has no saved session for a server. %@ = server name."
            )
            connectingWorkspaceId = nil
            withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
            progressBarOffset = -200
            return
        }

        if let sessionName = target?.sessionName {
            switch attachTarget {
            case .server(let context):
                await attachContextWorkspace(sessionName: sessionName, context: context)
            case .householdEndpoint(let endpoint):
                await attachHouseholdWorkspace(sessionName: sessionName, endpoint: endpoint)
            }
        } else {
            do {
                switch attachTarget {
                case .server(let context):
                    let workspace = try await apiClient.createWorkspace(
                        container: instance.container,
                        context: context
                    )
                    await attachContextWorkspace(sessionName: workspace.workspace.sessionId, context: context)
                case .householdEndpoint(let endpoint):
                    let workspace = try await apiClient.createNewWorkspace(
                        container: instance.container,
                        householdEndpoint: endpoint
                    )
                    workspaces.append(workspace)
                    selectedWorkspace = workspace
                    await attachHouseholdWorkspace(sessionName: workspace.sessionName, endpoint: endpoint)
                }
            } catch {
                resetAttachProgress(error: error.localizedDescription)
            }
        }
    }

    private func refreshedWorkspaces(for target: AttachTarget) async throws -> [SoyehtWorkspace] {
        switch target {
        case .server(let context):
            return try await apiClient.listWorkspaces(container: instance.container, context: context)
        case .householdEndpoint(let endpoint):
            return try await apiClient.listWorkspaces(
                container: instance.container,
                householdEndpoint: endpoint
            )
        }
    }

    private func attachContextWorkspace(sessionName: String, context: ServerContext) async {
            let wsUrl = apiClient.buildWebSocketURL(
                container: instance.container,
                sessionId: sessionName,
                context: context
            )

            guard let wsURL = URL(string: wsUrl) else {
                errorMessage = String(localized: "instancelist.error.invalidWebSocketURL")
                connectingWorkspaceId = nil
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                return
            }

            let result = await TerminalWebSocketHandshake.verify(url: wsURL, timeout: 10)
            switch result {
            case .success:
                resetAttachProgress()
                onAttach(wsUrl, sessionName, context)
            case .failure(let error):
                resetAttachProgress(error: error.localizedDescription)
            }
    }

    private func attachHouseholdWorkspace(sessionName: String, endpoint: URL) async {
        do {
            let token = try await apiClient.mintHouseholdTerminalAttachToken(
                container: instance.container,
                workspaceId: sessionName,
                householdEndpoint: endpoint
            )
            let request = try apiClient.makeHouseholdTerminalWebSocketRequest(
                endpoint: endpoint,
                container: instance.container,
                workspaceId: sessionName,
                attachToken: token.token
            )
            resetAttachProgress()
            onHouseholdAttach(request, sessionName, endpoint)
        } catch {
            resetAttachProgress(error: householdTerminalErrorMessage(for: error))
        }
    }

    private func resetAttachProgress(error: String? = nil) {
        connectingWorkspaceId = nil
        withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
        progressBarOffset = -200
        errorMessage = error
    }

    private func householdTerminalErrorMessage(for error: Error) -> String {
        if case SoyehtAPIClient.APIError.httpError(404, _) = error {
            return String(
                localized: "instancelist.error.householdTerminalUnsupported",
                defaultValue: "Terminal is not supported on this Mac yet.",
                comment: "Shown when a Mac household engine does not expose terminal attach routes yet."
            )
        }
        return error.localizedDescription
    }
}

// MARK: - Workspace Card

private struct WorkspaceCard: View {
    let workspace: SoyehtWorkspace
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.displayName)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text(LocalizedStringResource(
                    "instancelist.workspace.created",
                    defaultValue: "created \(workspace.displayCreated)",
                    comment: "Workspace row subtitle. %@ = relative time label (e.g. '5m ago')."
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
                    .background(Capsule().fill(SoyehtTheme.selection))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(SoyehtTheme.bgCard)
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? SoyehtTheme.historyGreenStrong : SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
        )
    }
}
