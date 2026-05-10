import SwiftUI
import SoyehtCore

/// Cena P8 — iPhone discovers newly-named casa via `_soyeht._tcp.` Bonjour.
/// Surfaces a notification card; tap-to-confirm starts the biometric flow.
struct CasaCalledView: View {
    let houseName: String
    let hostLabel: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 24) {
                    Text("🏠")
                        .font(.system(size: 64))
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text(verbatim: houseName)
                            .font(OnboardingFonts.headingLarge)
                            .foregroundColor(BrandColors.textPrimary)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "pairing.casaCalled.host",
                            defaultValue: "criada agora no \(hostLabel)",
                            comment: "Subtitle showing which Mac created the casa."
                        ))
                        .font(OnboardingFonts.callout)
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button(action: onConfirm) {
                            Text(LocalizedStringResource(
                                "pairing.casaCalled.cta",
                                defaultValue: "Entrar como primeiro morador",
                                comment: "CTA to begin pairing as the house's first member."
                            ))
                            .font(OnboardingFonts.bodyBold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(BrandColors.accentGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button(action: onDismiss) {
                            Text(LocalizedStringResource(
                                "pairing.casaCalled.dismiss",
                                defaultValue: "Agora não",
                                comment: "Dismiss button on casa discovery card."
                            ))
                            .font(OnboardingFonts.subheadline)
                            .foregroundColor(BrandColors.textMuted)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(28)
                .background(BrandColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 20)

                Spacer()
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .accessibilityLabel(Text(LocalizedStringResource(
            "pairing.casaCalled.a11y",
            defaultValue: "Casa \(houseName) criada no \(hostLabel). Toque para entrar como primeiro morador.",
            comment: "VoiceOver summary for the casa discovery card."
        )))
    }
}
