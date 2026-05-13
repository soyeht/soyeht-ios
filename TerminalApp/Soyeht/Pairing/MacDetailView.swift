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
                header

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

    private var header: some View {
        HStack(spacing: 8) {
            Button { onDismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(MacMirrorTreeStyle.headerIconFont)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            Text(client?.displayName ?? mac.name)
                .font(MacMirrorTreeStyle.headerFont)
                .foregroundColor(SoyehtTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .frame(height: 70)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(client?.displayName ?? mac.name), \(statusLabel)")
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
            VStack(alignment: .leading, spacing: 16) {
                if client.windows.isEmpty {
                    workspaceCollection(client.workspaces, windowTitle: nil)
                } else {
                    ForEach(Array(client.windows.enumerated()), id: \.element.id) { index, window in
                        windowSection(window, index: index)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 0)
            .padding(.bottom, 28)
        }
    }

    private func windowSection(_ window: MacWindowEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            treeDividerLabel(windowLabel(for: window, index: index))
            workspaceCollection(window.workspaces, windowTitle: window.title)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(windowSubtitle(window))
    }

    private func workspaceCollection(_ workspaces: [WorkspaceEntry], windowTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(workspaces) { workspace in
                workspaceSection(workspace)
            }
        }
    }

    private func workspaceSection(_ workspace: WorkspaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            treeChip(workspace.name, isActive: workspace.isActive)

            if !workspace.panes.isEmpty {
                VStack(spacing: 1) {
                    ForEach(workspace.orderedPaneRows) { item in
                        Button { onAttach(mac.macID, item.pane) } label: {
                            paneRow(item.pane, activePaneID: workspace.activePaneID)
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.pane.isAttachable)
                    }
                }
                .background(MacMirrorTreeStyle.rowGroupBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workspaceSubtitle(workspace))
    }

    private func windowSubtitle(_ window: MacWindowEntry) -> String {
        let workspaceCount = window.workspaces.count
        let paneCount = window.workspaces.reduce(0) { $0 + $1.paneCount }
        let state = window.isMiniaturized
            ? String(localized: "mac.detail.window.state.minimized")
            : (window.isKey
                ? String(localized: "mac.detail.window.state.key")
                : String(localized: "mac.detail.window.state.open"))
        return String(
            localized: "mac.detail.window.subtitle",
            defaultValue: "\(state) - \(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s") - \(paneCount) pane\(paneCount == 1 ? "" : "s")",
            comment: "Paired Mac window subtitle. %@ = localized window state, counts and plural suffixes are generated by the caller."
        )
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
                treeDividerLabel(String(localized: "mac.detail.section.activePanes", comment: "Section header in Mac detail — list of active panes."))

                VStack(spacing: 1) {
                    ForEach(client.panes) { pane in
                        Button { onAttach(mac.macID, pane) } label: {
                            paneRow(pane, activePaneID: nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(!pane.isAttachable)
                    }
                }
                .background(MacMirrorTreeStyle.rowGroupBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 22)
            .padding(.top, 0)
            .padding(.bottom, 28)
        }
    }

    private func paneRow(_ pane: PaneEntry, activePaneID: String?) -> some View {
        let focused = pane.isFocused || pane.id == activePaneID
        return HStack(spacing: 8) {
            Text(paneDisplayTitle(pane))
                .font(focused ? MacMirrorTreeStyle.paneFocusedFont : MacMirrorTreeStyle.paneFont)
                .foregroundColor(paneTextColor(pane, focused: focused))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if pane.isAttachable {
                Image(systemName: "chevron.right")
                    .font(MacMirrorTreeStyle.chevronFont)
                    .foregroundColor(focused ? SoyehtTheme.paneActiveBorder : SoyehtTheme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background {
            MacMirrorTreeStyle.rowBackground(focused: focused)
        }
        .overlay(alignment: .leading) {
            if focused {
                Rectangle()
                    .fill(SoyehtTheme.paneActiveBorder)
                    .frame(width: 2)
            }
        }
        .opacity(pane.isAttachable ? 1 : 0.72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paneAccessibilityLabel(pane, focused: focused))
    }

    private func treeDividerLabel(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MacMirrorTreeStyle.windowLabelFont)
                .foregroundColor(SoyehtTheme.textTertiary)
                .tracking(2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 15, alignment: .top)
            Rectangle()
                .fill(MacMirrorTreeStyle.dividerColor)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
    }

    private func treeChip(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(MacMirrorTreeStyle.workspaceFont)
            .foregroundColor(SoyehtTheme.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(MacMirrorTreeStyle.workspaceChipBackground)
    }

    private func windowLabel(for window: MacWindowEntry, index: Int) -> String {
        if window.isKey || index == 0 {
            return String(
                localized: "mac.detail.window.label.main",
                defaultValue: "WINDOW 1",
                comment: "Paired Mac mirror tree label for the key or first Mac window."
            )
        }
        return String(
            localized: "mac.detail.window.label.numbered",
            defaultValue: "WINDOW \(index + 1)",
            comment: "Paired Mac mirror tree label for non-key Mac windows. %lld = one-based window index."
        )
    }

    private func paneTextColor(_ pane: PaneEntry, focused: Bool) -> Color {
        if focused {
            return SoyehtTheme.selectionText
        }
        return pane.isAttachable ? SoyehtTheme.textSecondary : SoyehtTheme.textTertiary
    }

    private func paneDisplayTitle(_ pane: PaneEntry) -> String {
        pane.title.hasPrefix("@") ? String(pane.title.dropFirst()) : pane.title
    }

    private func paneAccessibilityLabel(_ pane: PaneEntry, focused: Bool) -> String {
        var parts = [paneDisplayTitle(pane), pane.agent, pane.status]
        if focused {
            parts.append(String(localized: "mac.detail.pane.focusedTag"))
        }
        if !pane.isAttachable {
            parts.append(String(localized: "mac.detail.pane.notAttachable", defaultValue: "not attachable", comment: "Accessibility suffix for placeholder panes that cannot be opened from iPhone."))
        }
        return parts.joined(separator: ", ")
    }

    static func color(for status: String) -> Color {
        switch status {
        case PaneWireStatus.active, PaneWireStatus.mirror: return SoyehtTheme.historyGreen
        case PaneWireStatus.idle:                          return SoyehtTheme.accentAmber
        case PaneWireStatus.dead:                          return SoyehtTheme.accentRed
        default:                                            return SoyehtTheme.historyGray
        }
    }
}

private enum MacMirrorTreeStyle {
    static let headerFont = Typography.monoNavTitle
    static let headerIconFont = Typography.iconMedium
    static let windowLabelFont = Typography.monoSmallMedium
    static let workspaceFont = Typography.monoCardTitle
    static let paneFont = Typography.monoCardBody
    static let paneFocusedFont = Typography.monoCardMedium
    static let chevronFont = Typography.iconSmall

    static var dividerColor: Color { SoyehtTheme.bgCardBorder }
    static var workspaceChipBackground: Color { SoyehtTheme.bgTertiary }
    static var rowGroupBackground: Color { SoyehtTheme.bgCardBorder }

    @ViewBuilder
    static func rowBackground(focused: Bool) -> some View {
        if focused {
            SoyehtTheme.paneActiveBg
        } else {
            SoyehtTheme.paneInactiveBg
        }
    }
}
