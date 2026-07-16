import SwiftUI
import SoyehtCore

struct PairedMacsListView: View {
    @Environment(\.dismiss) private var dismiss

    /// Source of truth for the Mac list. `ServerRegistry` is the
    /// single facade authorized to list/count paired servers; this
    /// view filters to the Mac subset. Per-row details that still
    /// need a `PairedMac` (currently: `MacAliasView` for the rename
    /// sheet) are fetched through `serverRegistry.pairedMac(for:)`
    /// — the view itself never reads `PairedMacsStore.shared.macs`.
    @ObservedObject private var serverRegistry = ServerRegistry.shared

    @State private var macToConfirmRemove: Server?
    @State private var macToRename: PairedMac?

    private var macs: [Server] {
        serverRegistry.operationalServers.filter { $0.kind == .mac }
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "common.accessibility.back",
                        defaultValue: "Back",
                        comment: "VoiceOver label for the back chevron in custom navigation headers."
                    )))
                    Text("settings.pairedMacs.title")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if macs.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .navigationBarHidden(true)
        .confirmationDialog(
            "settings.pairedMacs.remove.title",
            isPresented: Binding(
                get: { macToConfirmRemove != nil },
                set: { if !$0 { macToConfirmRemove = nil } }
            ),
            presenting: macToConfirmRemove
        ) { server in
            Button(LocalizedStringResource(
                "settings.pairedMacs.remove.confirm",
                defaultValue: "Remove “\(server.displayName)”",
                comment: "Destructive confirm button — removes the paired Mac. %@ = Mac display name."
            ), role: .destructive) {
                // Single entry point for "remove a paired server" —
                // `ServerRegistry.remove(serverID:)` dispatches into
                // `PairedMacsStore` (which clears the Keychain pairing
                // secret) and the mirror republishes `servers`. No
                // direct `PairedMacsStore.remove(macID:)` call from
                // the view.
                serverRegistry.remove(serverID: server.id)
            }
            Button("common.button.cancel", role: .cancel) {}
        } message: { _ in
            Text("settings.pairedMacs.remove.message")
        }
        // Rename sheet. Uses the same `MacAliasView` as the mandatory naming
        // flow on first pairing — single screen, single validation, single
        // dedupe path. See `MacAliasView` for the contract.
        .sheet(item: $macToRename) { mac in
            MacAliasView(mac: mac, onNamed: {
                macToRename = nil
            })
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 12) {
            Spacer()
            Image(systemName: "desktopcomputer")
                .font(Typography.iconEmptyState)
                .foregroundColor(SoyehtTheme.textTertiary)
            Text("settings.pairedMacs.empty.title")
                .font(Typography.monoBodyMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
            Text("settings.pairedMacs.empty.description")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("settings.pairedMacs.section.trusted")
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.historyGray)
                Text("settings.pairedMacs.section.trusted.description")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textTertiary)

                VStack(spacing: 0) {
                    ForEach(macs, id: \.id) { mac in
                        macRow(mac)
                        if mac.id != macs.last?.id {
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

    private func macRow(_ server: Server) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(Typography.iconSmall)
                .foregroundColor(SoyehtTheme.historyGray)
                // Use `minWidth` so the icon column lines up at default
                // Dynamic Type sizes but is allowed to grow at AX1+ sizes.
                // Fixed `width: 20` would clip the SF Symbol once the
                // system text size goes above AX1. Accessibility audit
                // 2026-05-08 P2.
                .frame(minWidth: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayName)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text(LocalizedStringResource(
                    "settings.pairedMacs.lastSeen",
                    defaultValue: "Last seen: \(Self.formatRelative(server.lastSeenAt))",
                    comment: "Paired Mac row subtitle. %@ = relative time (e.g. '3 min ago')."
                ))
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textTertiary)
                if let host = server.lastHost {
                    Text(host)
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textTertiary)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    // `MacAliasView` still takes a `PairedMac` because
                    // it shares the legacy validator/dedupe path used
                    // by the mandatory naming flow. Bridge via the
                    // registry helper instead of reaching into
                    // `PairedMacsStore.shared.macs` directly.
                    if let paired = serverRegistry.pairedMac(for: server.id) {
                        macToRename = paired
                    }
                } label: {
                    Text(LocalizedStringResource(
                        "settings.pairedMacs.rename",
                        defaultValue: "Rename",
                        comment: "Action that opens the rename sheet for a paired Mac."
                    ))
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.accentGreen)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.pairedMacs.rename")

                Button {
                    macToConfirmRemove = server
                } label: {
                    Text("common.button.remove")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.accentRed)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Formatter is `static let` so SwiftUI body re-renders don't re-allocate
    /// it once per row. Locale is snapshotted at first access (process start
    /// in practice, since the row appears in the Settings flow); changes to
    /// the system "App Language" via Scheme during debug require a process
    /// relaunch to take effect — same as the rest of the app's localized
    /// strings (xcstrings bundle is also process-scoped).
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func formatRelative(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}
