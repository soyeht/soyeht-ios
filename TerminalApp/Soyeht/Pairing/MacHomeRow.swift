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
        // CANONICAL: read `mac.displayName` (alias first, hostname fallback).
        // The Bonjour-discovered `client.displayName` is only used while the
        // user has not chosen an alias yet, because that name reflects the
        // current hostname rather than the user's preference.
        if !mac.needsAlias { return mac.displayName }
        return client.displayName.isEmpty ? mac.name : client.displayName
    }

    private var statusColor: Color {
        switch client.status {
        case .authenticated: return SoyehtTheme.historyGreen
        case .connecting:    return SoyehtTheme.accentAmber
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

/// Identity-only home row for the household engine's self/base machine.
///
/// Unlike `MacHomeRow`, this record has not completed the legacy HMAC pairing
/// flow and has no verified attach route yet. `reportedReachability` is an
/// unsigned diagnostic probe result from the `/machines` roster: the cached
/// address it targets is not authenticated, so even `true` never proves the
/// listed machine itself answered (a stale/poisoned cache entry can point the
/// probe at a different host running the same echo endpoint). It is a
/// diagnostic result only — never an enable, attach, route, or identity
/// signal. `nil` renders the original neutral "not checked" state, matching
/// both the local self machine (which never reports on itself this way) and
/// a genuinely unknown peer.
struct BaseMachineHomeRow: View {
    let server: Server
    let reportedReachability: Bool?

    init(server: Server, reportedReachability: Bool? = nil) {
        self.server = server
        self.reportedReachability = reportedReachability
    }

    private var statusColor: Color {
        switch reportedReachability {
        case .some(true): SoyehtTheme.statusOnline
        case .some(false): SoyehtTheme.statusOffline
        case .none: SoyehtTheme.historyGray
        }
    }

    private var statusText: String {
        switch reportedReachability {
        case .some(true): "last probe: reachable"
        case .some(false): "last probe: unreachable"
        case .none: "—"
        }
    }

    /// Matches the existing `server.kind == .mac ? "desktopcomputer" :
    /// "terminal"` convention used elsewhere (e.g. `ClawStoreServerPickerView`)
    /// so a Linux base machine doesn't render with Mac iconography.
    private var iconName: String {
        server.kind == .linux ? "terminal" : "desktopcomputer"
    }

    private var kindTag: String {
        server.kind == .linux ? "[owned linux]" : "[owned mac]"
    }

    private var kindAccessibilityLabel: String {
        server.kind == .linux ? "owned Linux machine" : "owned Mac"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(Typography.iconMedium)
                .foregroundColor(statusColor)
                .frame(minWidth: 22)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(server.displayName)
                    .font(Typography.monoCardTitle)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Text(verbatim: kindTag)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textTertiary)

            Text(verbatim: statusText)
                .font(Typography.monoTag)
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(SoyehtTheme.bgCard)
        .overlay(Rectangle().stroke(SoyehtTheme.bgTertiary, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(server.displayName), \(kindAccessibilityLabel), \(statusText)")
    }
}
