import SwiftUI
import SoyehtCore

// MARK: - Server List View

struct ServerListView: View {
    let onAddServer: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var servers: [PairedServer] = []
    @State private var activeId: String?
    @State private var confirmDelete: PairedServer?
    @State private var editingServer: PairedServer?
    @State private var testingServerId: String?
    @State private var connectionResults: [String: Bool] = [:]

    private let store = SessionStore.shared
    private let apiClient = SoyehtAPIClient.shared

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                List {
                    ForEach(servers) { server in
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
                store.removeServer(id: server.id)
                confirmDelete = nil
                reloadServers()
                if servers.isEmpty {
                    dismiss()
                    onAddServer()
                }
            }
        } message: {
            if let server = confirmDelete {
                Text(LocalizedStringResource(
                    "serverlist.alert.remove.message",
                    defaultValue: "remove \(server.displayName) (\(server.host))?",
                    comment: "Confirmation body. %1$@ = server name, %2$@ = server host."
                ))
            }
        }
        .sheet(item: $editingServer) { server in
            RenameServerSheet(server: server) { newName in
                store.renameServer(id: server.id, name: newName)
                reloadServers()
                editingServer = nil
            } onCancel: {
                editingServer = nil
            }
        }
        .onAppear { reloadServers() }
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

            Text(verbatim: "\(servers.count)")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Server Row

    private func serverRow(_ server: PairedServer) -> some View {
        let isActive = server.id == activeId

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(server.displayName)
                            .font(Typography.monoBodyLargeMedium)
                            .foregroundColor(SoyehtTheme.textPrimary)
                            .lineLimit(1)

                        ServerListPlatformBadge(server: server)
                    }

                    Text(server.host)
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
            store.setActiveServer(id: server.id)
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

    // MARK: - Helpers

    private func reloadServers() {
        servers = store.pairedServers
        activeId = store.activeServerId
    }

    @MainActor
    private func testConnection(_ server: PairedServer) async {
        testingServerId = server.id
        defer { testingServerId = nil }
        guard let context = store.context(for: server.id) else {
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

private struct ServerListPlatformBadge: View {
    let server: PairedServer

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
            Text(server.platformLabel)
                .font(Typography.monoTag)
        }
        .foregroundColor(SoyehtTheme.historyGreen)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(SoyehtTheme.historyGreenBadge)
        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
    }

    private var iconName: String {
        switch server.normalizedPlatform {
        case "macos": return "desktopcomputer"
        case "linux": return "terminal"
        default: return "externaldrive"
        }
    }
}

private struct RenameServerSheet: View {
    let server: PairedServer
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(server: PairedServer, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
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
                    ServerListPlatformBadge(server: server)
                    Text(server.host)
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
