import SwiftUI
import SoyehtCore

// TODO(i18n): user-facing strings are PT-BR literals to match the Welcome
// flow. Migrate to a `.xcstrings` catalog when the rest of the app is
// localised so both pt-BR and en-US ship in the same release.

/// Card representing a single Claw in the marketplace grid. Always
/// clickable (drives navigation to the detail view); the install button
/// is only rendered when the caller asks for it.
struct MacClawCardView: View {
    let claw: Claw
    var showInstallButton: Bool = false
    var onInstall: (() -> Void)?
    var onTap: (() -> Void)?

    private var info: ClawMockData.ClawStoreInfo {
        ClawMockData.storeInfo(for: claw.name)
    }

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tappable region — drives navigation to the detail view.
            Button {
                onTap?()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(claw.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(MacClawStoreTheme.textPrimary)
                        Spacer()
                        Text(claw.language.capitalized)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(MacClawStoreTheme.statusGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MacClawStoreTheme.statusGreenBg)
                            .clipShape(Capsule())
                    }

                    Text(info.tagline.isEmpty ? claw.description : info.tagline)
                        .font(.system(size: 11))
                        .foregroundColor(MacClawStoreTheme.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Label(claw.displayMinRAM, systemImage: "memorychip")
                            .font(.system(size: 10))
                            .foregroundColor(MacClawStoreTheme.textSecondary)
                        Label(claw.displayVersion, systemImage: "tag")
                            .font(.system(size: 10))
                            .foregroundColor(MacClawStoreTheme.textSecondary)
                    }

                    stateRow
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Install button lives outside the navigation button so clicks
            // on it do NOT also trigger navigation.
            if showInstallButton, case .notInstalled = claw.installState, let onInstall {
                Button("Instalar", action: onInstall)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(hovering ? MacClawStoreTheme.bgRowHover : MacClawStoreTheme.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    private var borderColor: Color {
        switch claw.installState {
        case .installed:                return MacClawStoreTheme.statusGreen
        case .installedButBlocked:      return MacClawStoreTheme.accentAmber
        case .installing, .uninstalling: return MacClawStoreTheme.statusGreen.opacity(0.5)
        case .installFailed:            return Color(hex: "#EF4444")
        default:                        return MacClawStoreTheme.bgCardBorder
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch claw.installState {
        case .installed:
            Text("Instalada")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(MacClawStoreTheme.statusGreen)
        case .installedButBlocked(let reasons):
            Text(reasons.first?.displayMessage ?? "Bloqueada")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(MacClawStoreTheme.accentAmber)
        case .installing(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress?.fraction ?? 0.1)
                    .progressViewStyle(.linear)
                    .tint(MacClawStoreTheme.statusGreen)
                Text("\(progress?.percent ?? 0)%")
                    .font(.system(size: 10))
                    .foregroundColor(MacClawStoreTheme.textMuted)
            }
        case .uninstalling:
            Text("Removendo…")
                .font(.system(size: 10))
                .foregroundColor(MacClawStoreTheme.textMuted)
        case .installFailed(let err):
            Text("Falhou: \(err)")
                .font(.system(size: 10))
                .foregroundColor(MacClawStoreTheme.textWarning)
                .lineLimit(2)
        case .notInstalled:
            Text("Não instalada")
                .font(.system(size: 10))
                .foregroundColor(MacClawStoreTheme.textComment)
        case .unknown:
            Text("Estado desconhecido")
                .font(.system(size: 10))
                .foregroundColor(MacClawStoreTheme.textWarning)
        }
    }
}
