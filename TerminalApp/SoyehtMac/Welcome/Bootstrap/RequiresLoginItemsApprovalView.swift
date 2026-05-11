import SwiftUI
import SoyehtCore
import AppKit

/// Shown when `SMAppService.register()` returns `.requiresApproval`.
/// Guides the user to grant Login Items permission in System Settings per FR-126.
/// Tone: educativo, não burocrático (FR-119 — never says "erro").
struct RequiresLoginItemsApprovalView: View {
    let onRetry: () -> Void

    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    @State private var arrowOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringResource(
                    "bootstrap.approval.title",
                    defaultValue: "Uma permissão rápida",
                    comment: "RequiresLoginItemsApproval title. Non-alarmist, educational tone."
                ))
                .font(MacTypography.Fonts.Display.heroTitle)
                .foregroundColor(BrandColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "bootstrap.approval.body",
                    defaultValue: "Para o Soyeht continuar vivo neste Mac, precisamos que você habilite-o em Configurações do Sistema → Geral → Itens de Login.",
                    comment: "Explains why Login Items permission is needed. Uses approved vocabulary (FR-002)."
                ))
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textMuted)
            }
            .padding(.bottom, 32)

            arrowIndicator
                .padding(.bottom, 32)

            HStack {
                Spacer()
                Button(action: openSettings) {
                    Text(LocalizedStringResource(
                        "bootstrap.approval.cta",
                        defaultValue: "Abrir Configurações",
                        comment: "CTA: opens System Settings > Login Items deeplink."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(BrandColors.buttonTextOnAccent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 28)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button(action: onRetry) {
                    Text(LocalizedStringResource(
                        "bootstrap.approval.retry",
                        defaultValue: "Já habilitei",
                        comment: "Secondary CTA: user confirmed they approved Login Items."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(BrandColors.readableTextOnSelection)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(BrandColors.selection)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                arrowOffset = 8
            }
        }
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "bootstrap.approval.step",
            defaultValue: "Passo 1 de 3",
            comment: "Step indicator shown on the Login Items approval screen."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.readableTextOnSelection)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.selection)
        .clipShape(Capsule())
    }

    private var arrowIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(BrandColors.accentGreen)
                .offset(x: arrowOffset)
                .accessibilityHidden(true)

            Text(LocalizedStringResource(
                "bootstrap.approval.hint",
                defaultValue: "Configurações do Sistema → Geral → Itens de Login",
                comment: "Path hint shown with animated arrow pointing toward System Settings."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textPrimary)
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.approval.hint.a11y",
            defaultValue: "Caminho: Configurações do Sistema, Geral, Itens de Login",
            comment: "VoiceOver label for the animated arrow path hint."
        )))
    }

    private func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}
