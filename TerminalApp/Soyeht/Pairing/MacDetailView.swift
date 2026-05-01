import SwiftUI
import SoyehtCore

/// Tap on a paired Mac in the home list opens this sheet. Lists the Mac's
/// live panes from the MacPresenceClient and lets the user pick one to attach
/// to (no QR required).
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
                } else if let client, client.panes.isEmpty {
                    emptyState(client: client)
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
        case .connecting:    return Color.yellow
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
                            paneRow(pane)
                        }
                        .buttonStyle(.plain)
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

    private func paneRow(_ pane: PaneEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: pane.iconName)
                .font(Typography.iconSmall)
                .foregroundColor(SoyehtTheme.historyGreen)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.color(for: pane.status))
                        .frame(width: 6, height: 6)
                    Text("[\(pane.agent)]")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textTertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
