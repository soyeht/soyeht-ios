import SwiftUI

// MARK: - Instance List View

struct InstanceListView: View {
    let onConnect: (String, SoyehtInstance, String) -> Void // (wsUrl, instance, sessionName)
    let onAddInstance: () -> Void
    let onLogout: () -> Void
    @Binding var autoSelectInstance: SoyehtInstance?
    @Binding var autoSelectSessionName: String?

    @State private var pendingSessionName: String?
    @State private var instances: [SoyehtInstance] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedInstance: SoyehtInstance?
    @State private var instanceActionError: String?
    @State private var confirmDelete: SoyehtInstance?
    @State private var showServerList = false

    private let apiClient = SoyehtAPIClient.shared
    private let store = SessionStore.shared

    private var onlineCount: Int { instances.filter(\.isOnline).count }
    private var offlineCount: Int { instances.filter { !$0.isOnline }.count }

    @State private var clawPath = NavigationPath()

    private var serverCount: Int { store.pairedServers.count }

    var body: some View {
        NavigationStack(path: $clawPath) {
            ZStack {
                SoyehtTheme.bgPrimary.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack {
                        HStack(spacing: 0) {
                            Text("> ")
                                .foregroundColor(SoyehtTheme.accentGreen)
                            Text("soyeht")
                                .foregroundColor(SoyehtTheme.textPrimary)
                        }
                        .font(.system(size: 20, weight: .bold, design: .monospaced))

                        Spacer()

                        HStack(spacing: 12) {
                            Button(action: onAddInstance) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 16))
                                    .foregroundColor(SoyehtTheme.textSecondary)
                            }
                            Button(action: onLogout) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 16))
                                    .foregroundColor(SoyehtTheme.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)

                    // Section label
                    Text("// claws")
                        .font(SoyehtTheme.labelFont)
                        .foregroundColor(SoyehtTheme.textComment)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                    if isLoading {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                ProgressView().tint(SoyehtTheme.accentGreen)
                                Text("loading claws...")
                                    .font(SoyehtTheme.smallMono)
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
                                Text("[!] \(error)")
                                    .font(SoyehtTheme.smallMono)
                                    .foregroundColor(SoyehtTheme.textWarning)
                                    .multilineTextAlignment(.center)
                                Button("retry") { Task { await loadInstances() } }
                                    .font(SoyehtTheme.labelFont)
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
                                ForEach(instances) { instance in
                                    InstanceCard(instance: instance)
                                        .accessibilityIdentifier(AccessibilityID.InstanceList.instanceCard(instance.id))
                                        .onTapGesture {
                                            if instance.isOnline {
                                                selectedInstance = instance
                                            }
                                        }
                                        .contextMenu {
                                            if instance.isOnline {
                                                Button { Task { await performInstanceAction(instance, action: .stop) } } label: {
                                                    Label("stop", systemImage: "stop.circle")
                                                }
                                                Button { Task { await performInstanceAction(instance, action: .restart) } } label: {
                                                    Label("restart", systemImage: "arrow.clockwise.circle")
                                                }
                                                Button { Task { await performInstanceAction(instance, action: .rebuild) } } label: {
                                                    Label("rebuild", systemImage: "arrow.triangle.2.circlepath")
                                                }
                                            } else {
                                                Button { Task { await performInstanceAction(instance, action: .restart) } } label: {
                                                    Label("start", systemImage: "play.circle")
                                                }
                                            }
                                            Divider()
                                            Button(role: .destructive) { confirmDelete = instance } label: {
                                                Label("delete", systemImage: "trash")
                                            }
                                        }
                                }

                                // Claw Store button
                                Button(action: { clawPath.append(ClawRoute.store) }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "storefront")
                                            .font(SoyehtTheme.bodyMono)
                                            .foregroundColor(SoyehtTheme.historyGreen)
                                        Text("claw store")
                                            .font(SoyehtTheme.cardTitle)
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
                                    .font(SoyehtTheme.bodyMono)
                                    .foregroundColor(SoyehtTheme.textComment)
                                Text("\(serverCount) server\(serverCount == 1 ? "" : "s") connected")
                                    .font(SoyehtTheme.labelRegular)
                                    .foregroundColor(SoyehtTheme.textPrimary)
                                Circle()
                                    .fill(SoyehtTheme.historyGreen)
                                    .frame(width: 6, height: 6)
                                Spacer()
                                Text(">>")
                                    .font(SoyehtTheme.labelRegular)
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
                switch route {
                case .store:
                    ClawStoreView()
                case .detail(let claw):
                    ClawDetailView(claw: claw)
                case .setup(let claw):
                    ClawSetupView(claw: claw)
                }
            }
        }
        .task {
            // Auto-select immediately (sheet opens without waiting for network)
            if let auto = autoSelectInstance {
                pendingSessionName = autoSelectSessionName
                selectedInstance = auto
                autoSelectInstance = nil
                autoSelectSessionName = nil
            }
            await loadInstances()
        }
        .sheet(item: $selectedInstance, onDismiss: {
            pendingSessionName = nil
            store.clearNavigationState()
        }) { instance in
            SessionListSheet(
                instance: instance,
                onAttach: { wsUrl, sessionName in
                    onConnect(wsUrl, instance, sessionName)
                },
                preselectedSession: pendingSessionName
            )
        }
        .onChange(of: selectedInstance?.id) { newId in
            if let instance = selectedInstance, newId != nil {
                store.saveNavigationState(NavigationState(
                    serverId: store.activeServerId ?? "",
                    instanceId: instance.id,
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
                if let instance = confirmDelete {
                    Task { await performInstanceAction(instance, action: .delete) }
                }
                confirmDelete = nil
            }
        } message: {
            Text("this will permanently delete \(confirmDelete?.name ?? "this instance"). this cannot be undone.")
        }
        .sheet(isPresented: $showServerList) {
            ServerListView(onAddServer: {
                showServerList = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onAddInstance()
                }
            })
        }
        .onChange(of: showServerList) { isPresented in
            if !isPresented {
                Task { await loadInstances() }
            }
        }
    }

    // MARK: - Instance Actions

    private func performInstanceAction(_ instance: SoyehtInstance, action: InstanceAction) async {
        do {
            try await apiClient.instanceAction(id: instance.id, action: action)
            await loadInstances()
        } catch {
            await MainActor.run {
                instanceActionError = error.localizedDescription
            }
        }
    }

    private func loadInstances() async {
        isLoading = true
        errorMessage = nil
        let cached = store.loadInstances()
        if !cached.isEmpty { instances = cached; isLoading = false }
        do {
            instances = try await apiClient.getInstances()
            isLoading = false
        } catch {
            if instances.isEmpty { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }
}

// MARK: - Instance Card

private struct InstanceCard: View {
    let instance: SoyehtInstance

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(instance.isOnline ? SoyehtTheme.statusOnline : SoyehtTheme.statusOffline)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(instance.name)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text(instance.displayFqdn)
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Spacer()

            Text(instance.displayTag)
                .font(SoyehtTheme.tagFont)
                .foregroundColor(SoyehtTheme.textSecondary)

            Text(">>")
                .font(SoyehtTheme.tagFont)
                .foregroundColor(SoyehtTheme.textComment)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(SoyehtTheme.bgCard)
                .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
        )
        .opacity(instance.isOnline ? 1.0 : 0.5)
    }
}

// MARK: - Session List Sheet (design node ec3Zq)

private struct SessionListSheet: View {
    let instance: SoyehtInstance
    let onAttach: (String, String) -> Void // (wsUrl, sessionName)
    var preselectedSession: String? = nil

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

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Nav header
                HStack(spacing: 10) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                            Text(instance.name)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(SoyehtTheme.textSecondary)
                    }

                    Circle()
                        .fill(SoyehtTheme.statusOnline)
                        .frame(width: 6, height: 6)

                    Spacer()

                    Text(instance.displayTag)
                        .font(SoyehtTheme.tagFont)
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
                            Text("loading sessions...")
                                .font(SoyehtTheme.smallMono)
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
                            Text("[!] \(error)")
                                .font(SoyehtTheme.smallMono)
                                .foregroundColor(SoyehtTheme.textWarning)
                                .multilineTextAlignment(.center)
                            Button("retry") { Task { await loadWorkspaces() } }
                                .font(SoyehtTheme.labelFont)
                                .foregroundColor(SoyehtTheme.accentGreen)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("// tmux sessions")
                                .font(SoyehtTheme.labelFont)
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
                                            Label("Delete", systemImage: "trash")
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
                                            Label("Delete", systemImage: "trash")
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
                                        Text("+ new session")
                                    }
                                    .font(SoyehtTheme.bodyMono)
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

                            Text("\(workspaces.count) active session\(workspaces.count == 1 ? "" : "s")  ·  swipe left to delete")
                                .font(SoyehtTheme.smallMono)
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
                    Text("[!] \(error)")
                        .font(SoyehtTheme.smallMono)
                        .foregroundColor(SoyehtTheme.textWarning)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Spacer().frame(height: 30)
            }
        }
        .accessibilityIdentifier(AccessibilityID.InstanceList.sessionSheet)
        .task { await loadWorkspaces() }
        .alert("Rename Session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Session name", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                guard let ws = renameTarget else { return }
                Task { await performRename(workspace: ws, newName: renameText) }
            }
        } message: {
            Text("Enter a new name for this session.")
        }
        .alert("New Session", isPresented: $showNewSessionAlert) {
            TextField("Session name", text: $newSessionName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                Task { await createNewWorkspace(name: newSessionName) }
            }
        } message: {
            Text("Enter a name for the new session.")
        }
        .alert("New Window", isPresented: $showNewWindowAlert) {
            TextField("Window name (optional)", text: $newWindowName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                Task { await createNewWindow(name: newWindowName) }
            }
        } message: {
            Text("Enter a name for the new window, or leave empty.")
        }
        .alert("Rename Window", isPresented: Binding(
            get: { windowRenameTarget != nil },
            set: { if !$0 { windowRenameTarget = nil } }
        )) {
            TextField("Window name", text: $windowRenameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { windowRenameTarget = nil }
            Button("Rename") {
                guard let w = windowRenameTarget else { return }
                Task { await performWindowRename(window: w, newName: windowRenameText) }
            }
        } message: {
            Text("Enter a new name for this window.")
        }
        .alert("Cannot Close Window", isPresented: Binding(
            get: { lastWindowError != nil },
            set: { if !$0 { lastWindowError = nil } }
        )) {
            Button("OK", role: .cancel) { lastWindowError = nil }
        } message: {
            Text(lastWindowError ?? "Cannot close the last window in a session.")
        }
        .alert("Rename Tab", isPresented: $showPaneRenameAlert) {
            TextField("Nickname", text: $paneRenameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { paneRenameTarget = nil }
            Button("Save") { savePaneNickname() }
            Button("Reset", role: .destructive) {
                paneRenameText = ""
                savePaneNickname()
            }
        } message: {
            Text("Set a local nickname for this pane tab.")
        }
        .alert("Kill Window", isPresented: Binding(
            get: { confirmKillWindow != nil },
            set: { if !$0 { confirmKillWindow = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmKillWindow = nil }
            Button("Kill", role: .destructive) {
                if let w = confirmKillWindow { Task { await killWindow(w) } }
                confirmKillWindow = nil
            }
        } message: {
            Text("This will close window \"\(confirmKillWindow?.name ?? "")\" and all its panes.")
        }
        .alert("Kill Pane", isPresented: Binding(
            get: { confirmKillPane != nil },
            set: { if !$0 { confirmKillPane = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmKillPane = nil }
            Button("Kill", role: .destructive) {
                if let kp = confirmKillPane { Task { await killPane(kp.pane, in: kp.window) } }
                confirmKillPane = nil
            }
        } message: {
            Text("This will close this pane and any running process in it.")
        }
    }

    @ViewBuilder
    private func windowsSection(workspace: SoyehtWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("// windows · \(workspace.displayName)")
                .font(SoyehtTheme.labelFont)
                .foregroundColor(SoyehtTheme.textComment)

            if isLoadingWindows {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView().tint(SoyehtTheme.historyGreen)
                        Text("loading windows...")
                            .font(SoyehtTheme.smallMono)
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
                            Text("connecting...")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                        } else {
                            Text("$")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                            Text("connect")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
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

                Text("no active tmux session  ·  connect to start")
                    .accessibilityIdentifier(AccessibilityID.InstanceList.emptyState)
                    .font(SoyehtTheme.smallMono)
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
                        Text("+ new window")
                    }
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
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
        do {
            workspaces = try await apiClient.listWorkspaces(container: instance.container)
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
        let task = Task {
            do {
                let result = try await apiClient.listWindows(container: instance.container, session: session)
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
        do {
            let newWs = try await apiClient.createNewWorkspace(container: instance.container, name: finalName)
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
        do {
            try await apiClient.deleteWorkspace(container: instance.container, workspaceId: ws.id)
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
            if let refreshed = try? await apiClient.listWorkspaces(container: instance.container) {
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
        do {
            try await apiClient.renameWorkspace(container: instance.container, workspaceId: workspace.id, newName: trimmed)
            // Reload workspaces to reflect the new name
            workspaces = try await apiClient.listWorkspaces(container: instance.container)
            selectedWorkspace = workspaces.first { $0.id == workspace.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func killSelectedWorkspace() async {
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        isKilling = true
        errorMessage = nil
        do {
            try await apiClient.deleteWorkspace(container: instance.container, workspaceId: ws.id)
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
            if let refreshed = try? await apiClient.listWorkspaces(container: instance.container) {
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
        await withTaskGroup(of: (Int, [TmuxPane]).self) { group in
            for window in windows {
                group.addTask {
                    let panes = (try? await apiClient.listPanes(
                        container: instance.container,
                        session: session,
                        windowIndex: window.index
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
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        connectingWindowIndex = window.index
        do {
            try await apiClient.selectWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index
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
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        errorMessage = nil
        do {
            try await apiClient.killWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index
            )
            windows.removeAll { $0.index == window.index }
            panesByWindow.removeValue(forKey: window.index)
            await loadWorkspaces()
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(400, let msg) = error {
                lastWindowError = msg ?? "Cannot close the last window in a session."
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createNewWindow(name: String?) async {
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        isCreatingWindow = true
        errorMessage = nil
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            let newWindow = try await apiClient.createWindow(
                container: instance.container,
                session: ws.sessionName,
                name: finalName
            )
            windows.append(newWindow)
            // Fetch panes for the new window
            let panes = (try? await apiClient.listPanes(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: newWindow.index
            )) ?? []
            panesByWindow[newWindow.index] = panes
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreatingWindow = false
    }

    private func performWindowRename(window: TmuxWindow, newName: String) async {
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await apiClient.renameWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                name: trimmed
            )
            // Reload windows to get updated names
            await loadWindows(session: ws.sessionName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pane Actions

    private func selectPaneAndAttach(_ pane: TmuxPane, in window: TmuxWindow) async {
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        connectingWindowIndex = window.index
        do {
            try await apiClient.selectWindow(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index
            )
            try await apiClient.selectPane(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                paneIndex: pane.index
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
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        do {
            // Select last pane so split always appends at the end
            if let lastPane = (panesByWindow[window.index] ?? []).max(by: { $0.index < $1.index }) {
                try await apiClient.selectPane(
                    container: instance.container,
                    session: ws.sessionName,
                    windowIndex: window.index,
                    paneIndex: lastPane.index
                )
            }
            try await apiClient.splitPane(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index
            )
            let panes = (try? await apiClient.listPanes(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index
            )) ?? []
            panesByWindow[window.index] = panes
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func killPane(_ pane: TmuxPane, in window: TmuxWindow) async {
        guard let ws = selectedWorkspace ?? workspaces.first else { return }
        do {
            try await apiClient.killPane(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index,
                paneIndex: pane.index
            )
            // Clean up nickname for the killed pane
            prefs.setPaneNickname(nil, container: instance.container, session: ws.sessionName, window: window.index, paneId: pane.paneId)
            let panes = (try? await apiClient.listPanes(
                container: instance.container,
                session: ws.sessionName,
                windowIndex: window.index
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

        guard let host = store.apiHost, let token = store.sessionToken else {
            connectingWindowIndex = nil
            withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
            progressBarOffset = -200
            return
        }

        if let sessionName = target?.sessionName {
            let wsUrl = apiClient.buildWebSocketURL(
                host: host,
                container: instance.container,
                sessionId: sessionName,
                token: token
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
                onAttach(wsUrl, sessionName)
            case .failure(let error):
                connectingWindowIndex = nil
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                errorMessage = error.localizedDescription
            }
        } else {
            do {
                let workspace = try await apiClient.createWorkspace(
                    container: instance.container
                )
                let sessionName = workspace.workspace.sessionId
                let wsUrl = apiClient.buildWebSocketURL(
                    host: host,
                    container: instance.container,
                    sessionId: sessionName,
                    token: token
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
                    onAttach(wsUrl, sessionName)
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
            Text("$")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(SoyehtTheme.accentGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.displayName)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text("\(workspace.displayWindowCount) window\(workspace.displayWindowCount == 1 ? "" : "s")  ·  created \(workspace.displayCreated)")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Spacer()

            if workspace.isAttached {
                Text("attached")
                    .font(SoyehtTheme.tagFont)
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
                    Text("\(window.index):")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(SoyehtTheme.historyGreen)

                    Text(window.displayName)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()

                    Text(">>")
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
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
                                    Label("Rename Tab", systemImage: "pencil")
                                }
                                Button(role: .destructive) { onKillPane(pane) } label: {
                                    Label("Kill Pane", systemImage: "xmark.circle")
                                }
                            }

                            if pane.active {
                                Button(action: onSplitPane) {
                                    Text("+")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
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
                .font(.system(size: 13, weight: .regular, design: .monospaced))
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
