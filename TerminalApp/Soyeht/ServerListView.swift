import SwiftUI
import SoyehtCore

// MARK: - Server List View

struct ServerListView: View {
    let onAddServer: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var servers: [PairedServer] = []
    @State private var activeId: String?
    @State private var confirmDelete: PairedServer?

    private let store = SessionStore.shared

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
                                    Text("remove")
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
        .alert("remove server", isPresented: .init(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("cancel", role: .cancel) { confirmDelete = nil }
            Button("remove", role: .destructive) {
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
                Text("remove \(server.name) (\(server.host))?")
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
                Image(systemName: "chevron.left")
                    .font(Typography.monoBody)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Text("servers")
                .font(Typography.monoPageTitle)
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Text("\(servers.count)")
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

        return Button {
            store.setActiveServer(id: server.id)
            activeId = server.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name)
                        .font(Typography.monoCardTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Text(server.host)
                        .font(Typography.monoCardBody)
                        .foregroundColor(SoyehtTheme.textSecondary)

                    HStack(spacing: 8) {
                        if let role = server.role {
                            Text(role)
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textComment)
                        }

                        Text(formatDate(server.pairedAt))
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textComment)
                    }
                }

                Spacer()

                if isActive {
                    activeBadge
                        .accessibilityIdentifier(AccessibilityID.ServerList.activeBadge(server.id))
                }
            }
            .padding(16)
            .background(SoyehtTheme.bgPrimary)
            .overlay(
                Rectangle()
                    .stroke(isActive ? SoyehtTheme.historyGreen.opacity(0.33) : SoyehtTheme.bgCardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active Badge

    private var activeBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(SoyehtTheme.historyGreen)
                .frame(width: 6, height: 6)
            Text("active")
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

    // MARK: - Add Server Button

    private var addServerButton: some View {
        Button {
            dismiss()
            onAddServer()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(Typography.monoCardBody)
                Text("add server")
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

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
