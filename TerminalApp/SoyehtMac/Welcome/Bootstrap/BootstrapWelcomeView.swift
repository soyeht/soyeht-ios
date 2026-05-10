import SwiftUI
import SoyehtCore

/// MA1 — "Bem-vindo ao Soyeht" welcome scene.
/// Presents a headline, short description, step indicator (1 de 3),
/// and a "Continuar" CTA. No admin prompts; no functional work done here.
struct BootstrapWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringResource(
                    "bootstrap.welcome.title",
                    defaultValue: "Bem-vindo ao Soyeht.",
                    comment: "MA1: Welcome headline. Shown on first launch of the bootstrap flow."
                ))
                .font(MacTypography.Fonts.Display.heroTitle)
                .foregroundColor(BrandColors.textPrimary)

                Text(LocalizedStringResource(
                    "bootstrap.welcome.subtitle",
                    defaultValue: "Vamos preparar este Mac em poucos passos.",
                    comment: "MA1: Welcome subtitle. Brief reassurance before the install steps."
                ))
                .font(MacTypography.Fonts.Display.heroSubtitle)
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Spacer()
                Button(action: onContinue) {
                    Text(LocalizedStringResource(
                        "bootstrap.welcome.cta",
                        defaultValue: "Continuar",
                        comment: "MA1: Primary CTA advancing to MA2 (InstallPreviewView)."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 28)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "bootstrap.welcome.cta.a11y",
                    defaultValue: "Continuar para a próxima etapa",
                    comment: "MA1 CTA VoiceOver label."
                )))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "bootstrap.welcome.step",
            defaultValue: "Passo 1 de 3",
            comment: "MA1: Step progress indicator shown at the top of the bootstrap flow."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.selection)
        .clipShape(Capsule())
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.welcome.step.a11y",
            defaultValue: "Etapa 1 de 3",
            comment: "MA1: VoiceOver label for the step indicator."
        )))
    }
}
