import SwiftUI

// MARK: - Instance List View

struct InstanceListView: View {
    let onConnect: (String, SoyehtInstance, String) -> Void // (wsUrl, instance, sessionName)
    let onAddInstance: () -> Void
    let onLogout: () -> Void

    @State private var instances: [SoyehtInstance] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedInstance: SoyehtInstance?

    private let apiClient = SoyehtAPIClient.shared
    private let store = SessionStore.shared

    private var onlineCount: Int { instances.filter(\.isOnline).count }
    private var offlineCount: Int { instances.filter { !$0.isOnline }.count }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    HStack(spacing: 0) {
                        Text("> ")
                            .foregroundColor(SoyehtTheme.accentGreen)
                        Text("soyeht")
                            .foregroundColor(.white)
                    }
                    .font(.system(size: 20, weight: .bold, design: .monospaced))

                    Spacer()

                    Button(action: onLogout) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 16))
                            .foregroundColor(SoyehtTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)

                // Section label
                Text("// instances")
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
                            Text("loading instances...")
                                .font(SoyehtTheme.smallMono)
                                .foregroundColor(SoyehtTheme.textSecondary)
                        }
                        Spacer()
                    }
                    Spacer()
                } else if let error = errorMessage {
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
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(instances) { instance in
                                InstanceCard(instance: instance)
                                    .onTapGesture {
                                        if instance.isOnline {
                                            selectedInstance = instance
                                        }
                                    }
                            }

                            Button(action: onAddInstance) {
                                Text("+ add instance")
                                    .font(SoyehtTheme.bodyMono)
                                    .foregroundColor(SoyehtTheme.accentGreen)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(SoyehtTheme.accentGreen.opacity(0.4), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                        .padding(.horizontal, 20)
                    }

                    // Footer
                    HStack(spacing: 0) {
                        Circle().fill(SoyehtTheme.statusOnline).frame(width: 6, height: 6)
                        Text(" \(onlineCount) connected").foregroundColor(SoyehtTheme.textSecondary)
                        Text("  //  ").foregroundColor(SoyehtTheme.textComment)
                        Text("\(offlineCount) offline").foregroundColor(SoyehtTheme.textSecondary)
                    }
                    .font(SoyehtTheme.smallMono)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
        }
        .task { await loadInstances() }
        .sheet(item: $selectedInstance) { instance in
            SessionListSheet(instance: instance) { wsUrl, sessionName in
                selectedInstance = nil
                onConnect(wsUrl, instance, sessionName)
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
                    .foregroundColor(.white)
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
            RoundedRectangle(cornerRadius: 8)
                .fill(SoyehtTheme.bgCard)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
        )
        .opacity(instance.isOnline ? 1.0 : 0.5)
    }
}

// MARK: - Session List Sheet (design node ec3Zq)

private struct SessionListSheet: View {
    let instance: SoyehtInstance
    let onAttach: (String, String) -> Void // (wsUrl, sessionName)

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

    private let apiClient = SoyehtAPIClient.shared
    private let store = SessionStore.shared

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
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(SoyehtTheme.accentGreen.opacity(0.4), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isCreating)
                                .padding(.top, 4)
                            }
                            .padding(.horizontal, 20)

                            Text("\(workspaces.count) active session\(workspaces.count == 1 ? "" : "s")  -  hold to rename/delete")
                                .font(SoyehtTheme.smallMono)
                                .foregroundColor(SoyehtTheme.textComment)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)

                            // Session details section
                            if let ws = selectedWorkspace ?? workspaces.first {
                                sessionDetailSection(workspace: ws)
                            }
                        }
                    }
                    .refreshable { await loadWorkspaces() }
                }

                if let error = errorMessage {
                    Text("[!] \(error)")
                        .font(SoyehtTheme.smallMono)
                        .foregroundColor(SoyehtTheme.textWarning)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: { Task { await attachToWorkspace() } }) {
                        VStack(spacing: 0) {
                            if isConnecting {
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(SoyehtTheme.bgTertiary)
                                    Rectangle()
                                        .fill(SoyehtTheme.accentAmber)
                                        .frame(width: 200)
                                        .offset(x: progressBarOffset)
                                }
                                .frame(height: 3)
                                .clipped()
                            }

                            HStack(spacing: 6) {
                                if !isConnecting {
                                    Text("$")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    Text("attach")
                                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                } else {
                                    Text("connecting...")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                }
                            }
                            .foregroundColor(isConnecting ? SoyehtTheme.historyGreen : .black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, isConnecting ? 10 : 14)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isConnecting
                                      ? SoyehtTheme.historyGreen.opacity(0.25)
                                      : SoyehtTheme.accentGreen)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting || workspaces.isEmpty)

                    Button(action: { Task { await killSelectedWorkspace() } }) {
                        HStack(spacing: 4) {
                            if isKilling {
                                ProgressView()
                                    .tint(isConnecting ? SoyehtTheme.accentAmber : .red)
                                    .scaleEffect(0.7)
                            }
                            Text("kill")
                        }
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(isConnecting ? SoyehtTheme.accentAmber : .red)
                        .frame(width: 80)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isConnecting ? Color.clear : SoyehtTheme.bgTertiary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(
                                            (isConnecting ? SoyehtTheme.accentAmber : Color.red).opacity(isConnecting ? 1 : 0.3),
                                            lineWidth: 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isKilling || selectedWorkspace == nil)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .animation(.easeInOut(duration: 0.3), value: isConnecting)
            }
        }
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
    }

    @ViewBuilder
    private func sessionDetailSection(workspace: SoyehtWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("// session details")
                .font(SoyehtTheme.labelFont)
                .foregroundColor(SoyehtTheme.textComment)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            HStack {
                Text("$ \(workspace.displayName)")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
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
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if isLoadingWindows {
                HStack {
                    Spacer()
                    ProgressView().tint(SoyehtTheme.accentGreen)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else if !windows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(windows) { window in
                        HStack {
                            Text("[\(window.displayIndex)]")
                                .font(SoyehtTheme.bodyMono)
                                .foregroundColor(SoyehtTheme.textComment)
                            Text(window.displayName)
                                .font(SoyehtTheme.bodyMono)
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(window.paneCount) pane\(window.paneCount > 1 ? "s" : "")")
                                .font(SoyehtTheme.smallMono)
                                .foregroundColor(SoyehtTheme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(SoyehtTheme.bgCard)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
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
            if let first = workspaces.first {
                await loadWindows(session: first.sessionName)
            }
        } catch {
            isLoadingWorkspaces = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadWindows(session: String) async {
        windowsTask?.cancel()
        isLoadingWindows = true
        let task = Task {
            do {
                let result = try await apiClient.listWindows(container: instance.container, session: session)
                guard !Task.isCancelled else { return }
                windows = result
            } catch {
                guard !Task.isCancelled else { return }
                windows = []
            }
            isLoadingWindows = false
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

    private func attachToWorkspace() async {
        let target = selectedWorkspace ?? workspaces.first
        let connectStart = Date()
        withAnimation(.easeInOut(duration: 0.3)) { isConnecting = true }
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            progressBarOffset = UIScreen.main.bounds.width
        }
        errorMessage = nil

        guard let host = store.apiHost, let token = store.sessionToken else {
            withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
            progressBarOffset = -200
            return
        }

        if let sessionName = target?.sessionName {
            // Attach to existing session
            let wsUrl = apiClient.buildWebSocketURL(
                host: host,
                container: instance.container,
                sessionId: sessionName,
                token: token
            )

            // Verify actual WebSocket handshake before navigating
            guard let wsURL = URL(string: wsUrl) else {
                errorMessage = "Invalid WebSocket URL"
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                return
            }

            let result = await WebSocketTerminalView.verifyHandshake(url: wsURL, timeout: 10)
            switch result {
            case .success:
                let remaining = 1.5 - Date().timeIntervalSince(connectStart)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                onAttach(wsUrl, sessionName)
            case .failure(let error):
                withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                progressBarOffset = -200
                errorMessage = error.localizedDescription
            }
        } else {
            // No existing session — create a new workspace first
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

                // Verify actual WebSocket handshake before navigating
                guard let wsURL = URL(string: wsUrl) else {
                    errorMessage = "Invalid WebSocket URL"
                    withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                    progressBarOffset = -200
                    return
                }

                let result = await WebSocketTerminalView.verifyHandshake(url: wsURL, timeout: 10)
                switch result {
                case .success:
                    let remaining = 1.5 - Date().timeIntervalSince(connectStart)
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                    withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                    progressBarOffset = -200
                    onAttach(wsUrl, sessionName)
                case .failure(let error):
                    withAnimation(.easeInOut(duration: 0.3)) { isConnecting = false }
                    progressBarOffset = -200
                    errorMessage = error.localizedDescription
                }
            } catch {
                let remaining = 1.5 - Date().timeIntervalSince(connectStart)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
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
                    .foregroundColor(.white)
                Text("\(workspace.windowCount) window\(workspace.windowCount == 1 ? "" : "s")  -  created \(workspace.displayCreated)")
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
            RoundedRectangle(cornerRadius: 8)
                .fill(SoyehtTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? SoyehtTheme.accentGreen.opacity(0.5) : SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
        )
    }
}
