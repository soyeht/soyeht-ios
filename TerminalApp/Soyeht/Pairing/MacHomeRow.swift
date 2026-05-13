import SwiftUI
import SoyehtCore

/// Compact row for a paired Mac in the home list (`InstanceListView`).
/// Mirrors `InstanceCard`'s visual density: icon + title + tag + ">>" chevron.
struct MacHomeRow: View {
    let mac: PairedMac
    @ObservedObject var client: MacPresenceClient

    init(mac: PairedMac, client: MacPresenceClient?) {
        self.mac = mac
        // Fall back to a disconnected stand-in so the view stays valid when
        // the registry hasn't spun up a client yet (e.g. missing endpoint).
        self.client = client ?? MacHomeRow.disconnectedStub(mac: mac)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(Typography.iconMedium)
                .foregroundColor(statusColor)
                // Use `minWidth` so the icon column lines up at default
                // Dynamic Type sizes but is allowed to grow at AX1+
                // sizes; fixed `width: 22` would clip the SF Symbol
                // once the system text size goes above AX1.
                // Accessibility audit 2026-05-08 P2.
                .frame(minWidth: 22)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(displayName)
                    .font(Typography.monoCardTitle)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Text(verbatim: "[mac]")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textTertiary)

            Text(verbatim: ">>")
                .font(Typography.monoTag)
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(SoyehtTheme.bgCard)
        .overlay(Rectangle().stroke(SoyehtTheme.bgTertiary, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName), \(statusLabel)")
    }

    private var displayName: String {
        client.displayName.isEmpty ? mac.name : client.displayName
    }

    private var statusColor: Color {
        switch client.status {
        case .authenticated: return SoyehtTheme.historyGreen
        case .connecting:    return .yellow
        case .offline:       return SoyehtTheme.historyGray
        case .idle:          return SoyehtTheme.historyGray
        }
    }

    private var statusLabel: String {
        switch client.status {
        case .authenticated:
            return String(localized: "mac.detail.status.online", defaultValue: "online", comment: "Accessibility status — Mac is connected.")
        case .connecting:
            return String(localized: "mac.home.subtitle.connecting", comment: "Subtitle under a paired Mac row while the WebSocket is connecting.")
        case .offline(let r):
            return String(
                localized: "mac.home.subtitle.offline",
                defaultValue: "offline (\(r))",
                comment: "Subtitle — Mac is offline. %@ = reason from server."
            )
        case .idle:
            return "—"
        }
    }

    /// Stub client for when the registry hasn't produced a real one yet.
    private static func disconnectedStub(mac: PairedMac) -> MacPresenceClient {
        MacPresenceClient(
            macID: mac.macID,
            deviceID: PairedMacsStore.shared.deviceID,
            secret: Data(),
            endpoint: nil,
            displayName: mac.name
        )
    }
}
