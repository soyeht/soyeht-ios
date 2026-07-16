import SwiftUI
import SoyehtCore

// MARK: - Server List View
//
// Renders every paired entity the iPhone knows about (Macs + Linux
// admin hosts) from the unified `ServerRegistry` source-of-truth. The
// list reacts live to mutations against either legacy store via the
// `ServerRegistry.installLegacyMirror` plumbing wired in AppDelegate —
// no manual reload needed.

struct ServerListView: View {
    let onAddServer: () -> Void

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var serverRegistry = ServerRegistry.shared

    @State private var activeId: String?
    @State private var confirmDelete: Server?
    @State private var editingServer: Server?
    @State private var testingServerId: String?
    @State private var connectionResults: [String: Bool] = [:]

    // Kept as credential adapter only (not as a listing source): the
    // "test connection" Linux affordance hits `validateSession`, which
    // needs a `ServerContext` (host + token) and that lookup belongs
    // to `SessionStore`. Listing, counting, renaming, and removing
    // go through `serverRegistry` exclusively.
    private let sessionStore = SessionStore.shared
    private let apiClient = SoyehtAPIClient.shared

    /// Servers sorted with Macs first (matches `// apps` ordering on
    /// the home screen), then Linux, both stable by `pairedAt`.
    private var sortedServers: [Server] {
        serverRegistry.operationalServers.sorted { a, b in
            if a.kind != b.kind { return a.kind == .mac }
            return a.pairedAt < b.pairedAt
        }
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                List {
                    ForEach(sortedServers, id: \.id) { server in
                        serverRow(server)
                            .accessibilityIdentifier(AccessibilityID.ServerList.serverRow(server.id))
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    confirmDelete = server
                                } label: {
                                    Text("serverlist.action.remove")
                                }
                                .tint(SoyehtTheme.accentRed)
                            }
                    }

                    addServerButton
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .alert("serverlist.alert.remove.title", isPresented: .init(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("common.button.cancel.lower", role: .cancel) { confirmDelete = nil }
            Button("serverlist.action.remove", role: .destructive) {
                guard let server = confirmDelete else { return }
                removeServer(server)
                confirmDelete = nil
                if serverRegistry.operationalServers.isEmpty {
                    dismiss()
                    onAddServer()
                }
            }
        } message: {
            if let server = confirmDelete {
                Text(LocalizedStringResource(
                    "serverlist.alert.remove.message",
                    defaultValue: "remove \(server.displayName) (\(server.lastHost ?? server.hostname))?",
                    comment: "Confirmation body. %1$@ = server name, %2$@ = server host."
                ))
            }
        }
        .sheet(item: $editingServer) { server in
            RenameServerSheet(server: server) { newName in
                renameServer(server, to: newName)
                editingServer = nil
            } onCancel: {
                editingServer = nil
            }
        }
        .onAppear { activeId = sessionStore.activeServerId }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text(verbatim: "<")
                    .font(Typography.monoPageTitle)
                    .foregroundColor(SoyehtTheme.accentGreen)
            }

            Text("serverlist.title")
                .font(Typography.monoPageTitle)
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Text(verbatim: "\(serverRegistry.operationalServers.count)")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Server Row

    private func serverRow(_ server: Server) -> some View {
        let isActive = server.id == activeId
        let hostText = server.lastHost ?? server.hostname

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(server.displayName)
                            .font(Typography.monoBodyLargeMedium)
                            .foregroundColor(SoyehtTheme.textPrimary)
                            .lineLimit(1)

                        ServerKindBadge(kind: server.kind)
                    }

                    Text(hostText)
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.textSecondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let role = server.role {
                            Text(role)
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textComment)
                        }

                        Text(formatDate(server.pairedAt))
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textComment)

                        if let result = connectionResults[server.id] {
                            connectionBadge(connected: result)
                        }
                    }
                }

                Spacer()

                if isActive {
                    activeBadge
                        .accessibilityIdentifier(AccessibilityID.ServerList.activeBadge(server.id))
                }
            }

            HStack(spacing: 10) {
                Button {
                    editingServer = server
                } label: {
                    Label("rename", systemImage: "pencil")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textPrimary)
                }
                .buttonStyle(.plain)

                if server.kind == .linux {
                    // The "test" action exercises `SoyehtAPIClient.validateSession`,
                    // which needs a `ServerContext` (host + token). Macs
                    // pair via household and use a different transport, so
                    // the button only shows for Linux until presence has
                    // a uniform per-kind API surface.
                    Button {
                        Task { await testConnection(server) }
                    } label: {
                        if testingServerId == server.id {
                            ProgressView()
                                .tint(SoyehtTheme.historyGreen)
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Label("test", systemImage: "bolt.horizontal")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(testingServerId == server.id)
                }

                Spacer()
            }
        }
        .padding(16)
        .background(SoyehtTheme.bgPrimary)
        .overlay(
            Rectangle()
                .stroke(isActive ? SoyehtTheme.historyGreenStrong : SoyehtTheme.bgCardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            sessionStore.setActiveServer(id: server.id)
            activeId = server.id
        }
    }

    // MARK: - Active Badge

    private var activeBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(SoyehtTheme.historyGreen)
                .frame(width: 6, height: 6)
            Text("serverlist.badge.active")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SoyehtTheme.historyGreenBadge)
        .overlay(
            Rectangle()
                .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
        )
    }

    private func connectionBadge(connected: Bool) -> some View {
        Text(connected ? "connected" : "offline")
            .font(Typography.monoTag)
            .foregroundColor(connected ? SoyehtTheme.historyGreen : SoyehtTheme.accentRed)
    }

    // MARK: - Add Server Button

    private var addServerButton: some View {
        Button {
            dismiss()
            onAddServer()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(Typography.monoCardBody)
                Text("serverlist.action.add")
                    .font(Typography.monoCardBody)
            }
            .foregroundColor(SoyehtTheme.historyGreen)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(SoyehtTheme.historyGreenBg)
            .overlay(
                Rectangle()
                    .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.ServerList.addServerButton)
    }

    // MARK: - Mutators
    //
    // Both rename and remove funnel through `ServerRegistry`, which
    // dispatches to the owning legacy store internally (Mac UUID id
    // / Keychain `pairing_secret` for Macs, `server_tokens` row for
    // Linux). The view does NOT branch on `server.kind` — that is
    // exactly the asymmetry PR-2 is supposed to remove. The mirror
    // fires its existing `onChange` / `onServersDidChange` hook and
    // republishes `servers`, so the row re-renders without us
    // touching the registry directly.

    private func renameServer(_ server: Server, to newName: String) {
        _ = serverRegistry.rename(serverID: server.id, to: newName)
    }

    private func removeServer(_ server: Server) {
        serverRegistry.remove(serverID: server.id)
    }

    @MainActor
    private func testConnection(_ server: Server) async {
        // Linux-only — see the row-level guard around the button.
        testingServerId = server.id
        defer { testingServerId = nil }
        guard let context = sessionStore.context(for: server.id) else {
            connectionResults[server.id] = false
            return
        }
        let connected = (try? await apiClient.validateSession(context: context)) ?? false
        connectionResults[server.id] = connected
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct ServerKindBadge: View {
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
        case .mac: return "mac"
        case .linux: return "linux"
        }
    }
}

private struct RenameServerSheet: View {
    let server: Server
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(server: Server, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.server = server
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: server.displayName)
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text(verbatim: "<")
                            .font(Typography.monoPageTitle)
                            .foregroundColor(SoyehtTheme.accentGreen)
                    }
                    Text(verbatim: "Rename")
                        .font(Typography.monoPageTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "server name")
                        .font(Typography.monoLabel)
                        .foregroundColor(SoyehtTheme.textComment)
                    TextField("", text: $name)
                        .font(Typography.monoBody)
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .padding(12)
                        .background(SoyehtTheme.bgCard)
                        .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
                }

                HStack(spacing: 8) {
                    ServerKindBadge(kind: server.kind)
                    Text(server.lastHost ?? server.hostname)
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.textSecondary)
                        .lineLimit(1)
                }

                Button {
                    onSave(name)
                } label: {
                    Label("save", systemImage: "checkmark")
                        .font(Typography.monoCardTitle)
                        .foregroundColor(SoyehtTheme.buttonTextOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(SoyehtTheme.historyGreen)
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }
}
