import SwiftUI
import SoyehtCore

struct PairedMacsListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var macs: [PairedMac] = []
    @State private var macToConfirmRemove: PairedMac?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }
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
        .onAppear(perform: reload)
        .confirmationDialog(
            "settings.pairedMacs.remove.title",
            isPresented: Binding(
                get: { macToConfirmRemove != nil },
                set: { if !$0 { macToConfirmRemove = nil } }
            ),
            presenting: macToConfirmRemove
        ) { mac in
            Button(LocalizedStringResource(
                "settings.pairedMacs.remove.confirm",
                defaultValue: "Remove “\(mac.name)”",
                comment: "Destructive confirm button — removes the paired Mac. %@ = Mac display name."
            ), role: .destructive) {
                PairedMacsStore.shared.remove(macID: mac.macID)
                reload()
            }
            Button("common.button.cancel", role: .cancel) {}
        } message: { _ in
            Text("settings.pairedMacs.remove.message")
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
                    ForEach(macs) { mac in
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

    private func macRow(_ mac: PairedMac) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(Typography.iconSmall)
                .foregroundColor(SoyehtTheme.historyGray)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(mac.name)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text(LocalizedStringResource(
                    "settings.pairedMacs.lastSeen",
                    defaultValue: "Last seen: \(Self.formatRelative(mac.lastSeenAt))",
                    comment: "Paired Mac row subtitle. %@ = relative time (e.g. '3 min ago')."
                ))
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textTertiary)
                if let host = mac.lastHost {
                    Text(host)
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textTertiary)
                }
            }

            Spacer()

            Button {
                macToConfirmRemove = mac
            } label: {
                Text("common.button.remove")
                    .font(Typography.monoTag)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private static func formatRelative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // Locale flows from the system — honors Scheme → App Language in debug.
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func reload() {
        macs = PairedMacsStore.shared.macs
    }
}
