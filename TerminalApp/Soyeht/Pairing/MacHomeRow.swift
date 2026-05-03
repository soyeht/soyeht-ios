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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(Typography.iconMedium)
                .foregroundColor(statusColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(displayName)
                        .font(Typography.monoCardTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)
                }
                Text(subtitle)
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textTertiary)
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

    private var subtitle: String {
        switch client.status {
        case .authenticated:
            let n = client.panes.count
            if n == 0 {
                return String(localized: "mac.home.subtitle.noPanes", comment: "Subtitle under a paired Mac row when it is online but has no panes.")
            }
            return String(
                localized: "mac.home.subtitle.paneCount",
                defaultValue: "\(n) pane\(n == 1 ? "" : "s")",
                comment: "Subtitle under a paired Mac row showing the number of panes. %lld = count."
            )
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
