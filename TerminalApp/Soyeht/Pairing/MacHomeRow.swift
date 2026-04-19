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
                .font(.system(size: 18))
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

            Text("[mac]")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textTertiary)

            Text(">>")
                .font(Typography.monoTag)
                .foregroundColor(statusColor.opacity(0.8))
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
            return n == 0 ? "nenhum pane ativo" : "\(n) pane\(n == 1 ? "" : "s")"
        case .connecting:    return "conectando…"
        case .offline(let r): return "offline (\(r))"
        case .idle:          return "—"
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
