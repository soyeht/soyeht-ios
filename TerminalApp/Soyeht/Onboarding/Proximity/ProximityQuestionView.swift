import SwiftUI
import SoyehtCore

/// Cena PB2 — "Tá perto do Mac agora?" (FR-024).
/// Confirms physical proximity before triggering AirDrop transfer.
struct ProximityQuestionView: View {
    let onNearby: () -> Void
    let onLater: () -> Void

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    illustration

                    VStack(spacing: 10) {
                        Text(LocalizedStringResource(
                            "proximity.title",
                            defaultValue: "Tá perto do Mac agora?",
                            comment: "Proximity question screen title."
                        ))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "proximity.subtitle",
                            defaultValue: "Vamos usar o AirDrop pra instalar o Soyeht no Mac. Fica fácil.",
                            comment: "Proximity subtitle explaining AirDrop will be used."
                        ))
                        .font(.system(size: 16))
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button(action: onNearby) {
                            Text(LocalizedStringResource(
                                "proximity.cta.nearby",
                                defaultValue: "Sim, estou no Mac",
                                comment: "CTA confirming user is near their Mac."
                            ))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(BrandColors.accentGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button(action: onLater) {
                            Text(LocalizedStringResource(
                                "proximity.cta.later",
                                defaultValue: "Vou fazer mais tarde",
                                comment: "Secondary action: defer setup to later."
                            ))
                            .font(.system(size: 15))
                            .foregroundColor(BrandColors.textMuted)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)

                Spacer()
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(BrandColors.accentGreen.opacity(0.12))
                .frame(width: 120, height: 120)

            HStack(spacing: -8) {
                Image(systemName: "iphone")
                    .font(.system(size: 32))
                    .foregroundColor(BrandColors.textPrimary)

                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(BrandColors.accentGreen)

                Image(systemName: "laptopcomputer")
                    .font(.system(size: 32))
                    .foregroundColor(BrandColors.textPrimary)
            }
        }
        .accessibilityHidden(true)
    }
}
