import SwiftUI
import SoyehtCore

/// Tap on a paired Mac in the home list opens this sheet. Mirrors the Mac's
/// open windows, workspaces and panes from the persistent presence channel.
struct MacDetailView: View {
    let mac: PairedMac
    let onAttach: (UUID, PaneEntry) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var registry = PairedMacRegistry.shared

    private var client: MacPresenceClient? {
        registry.client(for: mac.macID)
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Button { onDismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }
                    Text(client?.displayName ?? mac.name)
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Spacer()
                    statusDot
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if client == nil {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "questionmark.circle")
                            .font(Typography.iconEmptyState)
                            .foregroundColor(SoyehtTheme.textTertiary)
                        Text("pairing.mac.detail.clientNotStarted")
                            .font(Typography.monoBodyMedium)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }
                    Spacer()
                } else if let client, client.panes.isEmpty && client.windows.isEmpty && client.workspaces.isEmpty {
                    emptyState(client: client)
                } else if let client, !client.windows.isEmpty || !client.workspaces.isEmpty {
                    mirrorList(client: client)
                } else if let client {
                    panesList(client: client)
                }
            }
        }
        .navigationBarHidden(true)
    }

    @ViewBuilder
    private var statusDot: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textTertiary)
        }
    }

    private var statusColor: Color {
        switch client?.status {
        case .authenticated: return SoyehtTheme.historyGreen
        case .connecting:    return SoyehtTheme.accentAmber
        case .offline:       return SoyehtTheme.historyGray
        default:             return SoyehtTheme.historyGray
        }
    }

    private var statusLabel: String {
        switch client?.status {
        case .authenticated: return String(localized: "mac.detail.status.online", comment: "Status badge — Mac is online.")
        case .connecting:    return String(localized: "mac.detail.status.connecting", comment: "Status badge — Mac is connecting.")
        case .offline:       return String(localized: "mac.detail.status.offline", comment: "Status badge — Mac is offline.")
        default:             return "—"
        }
    }

    @ViewBuilder
    private func emptyState(client: MacPresenceClient) -> some View {
        Spacer()
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(Typography.iconEmptyState)
                .foregroundColor(SoyehtTheme.textTertiary)
            Text("mac.detail.empty.title")
                .font(Typography.monoBodyMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
            Text("mac.detail.empty.description")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textTertiary)
                .multilineTextAlignment(.center)
            if case .offline = client.status {
                Button("mac.detail.button.retryConnect") { client.connect() }
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.historyGreen)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        Spacer()
    }

    @ViewBuilder
    private func mirrorList(client: MacPresenceClient) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(LocalizedStringResource(
                    "mac.detail.section.windows",
                    defaultValue: "open windows",
                    comment: "Section header for the paired Mac mirror list."
                ))
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.historyGray)

                if client.windows.isEmpty {
                    workspaceCollection(client.workspaces, windowTitle: nil)
                } else {
                    ForEach(client.windows) { window in
                        windowSection(window)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
    }

    private func windowSection(_ window: MacWindowEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "macwindow")
                    .font(Typography.iconSmall)
                    .foregroundColor(window.isKey ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(window.title)
                        .font(Typography.monoBodyLargeMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(windowSubtitle(window))
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textTertiary)
                }

                Spacer()

                if window.isKey {
                    Image(systemName: "circle.fill")
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.historyGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(SoyehtTheme.bgCard)

            Rectangle().fill(SoyehtTheme.bgTertiary).frame(height: 1)
            workspaceCollection(window.workspaces, windowTitle: window.title)
        }
        .overlay(Rectangle().stroke(SoyehtTheme.bgTertiary, lineWidth: 1))
    }

    private func workspaceCollection(_ workspaces: [WorkspaceEntry], windowTitle: String?) -> some View {
        VStack(spacing: 0) {
            ForEach(workspaces) { workspace in
                workspaceSection(workspace)
                if workspace.id != workspaces.last?.id {
                    Rectangle().fill(SoyehtTheme.bgTertiary).frame(height: 1)
                }
            }
        }
    }

    private func workspaceSection(_ workspace: WorkspaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: workspace.isActive ? "rectangle.stack.fill" : "rectangle.stack")
                    .font(Typography.iconSmall)
                    .foregroundColor(workspace.isActive ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.name)
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(workspaceSubtitle(workspace))
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(workspace.isActive ? SoyehtTheme.bgSecondary : SoyehtTheme.bgPrimary)

            if !workspace.panes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(workspace.orderedPaneRows) { item in
                        Button { onAttach(mac.macID, item.pane) } label: {
                            paneRow(item.pane, depth: item.depth, activePaneID: workspace.activePaneID)
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.pane.isAttachable)
                    }
                }
            }
        }
    }

    private func windowSubtitle(_ window: MacWindowEntry) -> String {
        let workspaceCount = window.workspaces.count
        let paneCount = window.workspaces.reduce(0) { $0 + $1.paneCount }
        let state = window.isMiniaturized ? "minimized" : (window.isKey ? "key" : "open")
        return "\(state) - \(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s") - \(paneCount) pane\(paneCount == 1 ? "" : "s")"
    }

    private func workspaceSubtitle(_ workspace: WorkspaceEntry) -> String {
        var parts = [workspace.kind]
        if let branch = workspace.branch, !branch.isEmpty {
            parts.append(branch)
        }
        parts.append("\(workspace.paneCount) pane\(workspace.paneCount == 1 ? "" : "s")")
        if workspace.isActive {
            parts.append("active")
        }
        return parts.joined(separator: " - ")
    }

    @ViewBuilder
    private func panesList(client: MacPresenceClient) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("mac.detail.section.activePanes")
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.historyGray)
                Text(LocalizedStringResource(
                    "mac.detail.section.activePanes.hint",
                    defaultValue: "\(client.panes.count) pane\(client.panes.count == 1 ? "" : "s"). Tap to open on iPhone — no QR needed.",
                    comment: "Hint under the section header. %lld = pane count."
                ))
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textTertiary)

                VStack(spacing: 0) {
                    ForEach(client.panes) { pane in
                        Button { onAttach(mac.macID, pane) } label: {
                            paneRow(pane, depth: 0, activePaneID: nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(!pane.isAttachable)
                        if pane.id != client.panes.last?.id {
                            Rectangle().fill(SoyehtTheme.bgTertiary).frame(height: 1)
                        }
                    }
                }
                .overlay(Rectangle().stroke(SoyehtTheme.bgTertiary, lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
    }

    private func paneRow(_ pane: PaneEntry, depth: Int, activePaneID: String?) -> some View {
        let focused = pane.isFocused || pane.id == activePaneID
        return HStack(alignment: .center, spacing: 12) {
            if depth > 0 {
                Rectangle()
                    .fill(SoyehtTheme.bgTertiary)
                    .frame(width: CGFloat(min(depth, 4)) * 10, height: 1)
            }

            Image(systemName: pane.iconName)
                .font(Typography.iconSmall)
                .foregroundColor(pane.isAttachable ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(pane.isAttachable ? SoyehtTheme.textPrimary : SoyehtTheme.textTertiary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.color(for: pane.status))
                        .frame(width: 6, height: 6)
                    Text("[\(pane.agent)]")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textTertiary)
                    if focused {
                        Text("[focused]")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.historyGreen)
                    }
                }
            }
            Spacer()
            if pane.isAttachable {
                Image(systemName: "chevron.right")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(focused ? SoyehtTheme.bgSecondary : Color.clear)
    }

    static func color(for status: String) -> Color {
        switch status {
        case PaneWireStatus.active, PaneWireStatus.mirror: return SoyehtTheme.historyGreen
        case PaneWireStatus.idle:                          return .yellow
        case PaneWireStatus.dead:                          return .red
        default:                                            return SoyehtTheme.historyGray
        }
    }
}
