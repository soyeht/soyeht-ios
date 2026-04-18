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
                    Text("Macs pareados")
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
            "Remover este Mac?",
            isPresented: Binding(
                get: { macToConfirmRemove != nil },
                set: { if !$0 { macToConfirmRemove = nil } }
            ),
            presenting: macToConfirmRemove
        ) { mac in
            Button("Remover “\(mac.name)”", role: .destructive) {
                PairedMacsStore.shared.remove(macID: mac.macID)
                reload()
            }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("O segredo de pareamento será apagado. Pra voltar, escaneie um novo QR no Mac.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 12) {
            Spacer()
            Image(systemName: "desktopcomputer")
                .font(.system(size: 36))
                .foregroundColor(SoyehtTheme.textTertiary)
            Text("Nenhum Mac pareado")
                .font(Typography.monoBodyMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
            Text("Clique no botão QR de um pane no Mac e escaneie com a câmera.")
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
                Text("// trusted Macs")
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.historyGray)
                Text("iPhones pareados podem abrir panes destes Macs sem pedir confirmação. Remova aqui pra cortar o acesso.")
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
                .font(.system(size: 16))
                .foregroundColor(SoyehtTheme.historyGray)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(mac.name)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text("Último uso: \(Self.formatRelative(mac.lastSeenAt))")
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
                Text("Remover")
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
        formatter.locale = Locale(identifier: "pt_BR")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func reload() {
        macs = PairedMacsStore.shared.macs
    }
}
