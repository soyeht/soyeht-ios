import SwiftUI
import SoyehtCore

/// Scene PB2 — "Are you near your Mac now?" (FR-024).
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
                            defaultValue: "Are you near your Mac now?",
                            comment: "Proximity question screen title."
                        ))
                        .font(OnboardingFonts.heading)
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "proximity.subtitle",
                            defaultValue: "We'll help you get Soyeht running on your Mac with a download link.",
                            comment: "Proximity subtitle explaining the Mac setup handoff uses a download link."
                        ))
                        .font(OnboardingFonts.callout)
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button(action: onNearby) {
                            Text(LocalizedStringResource(
                                "proximity.cta.nearby",
                                defaultValue: "Yes, I'm at my Mac",
                                comment: "CTA confirming user is near their Mac."
                            ))
                            .font(OnboardingFonts.bodyBold)
                            .foregroundColor(BrandColors.buttonTextOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(BrandColors.accentGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button(action: onLater) {
                            Text(LocalizedStringResource(
                                "proximity.cta.later",
                                defaultValue: "I'll do it later",
                                comment: "Secondary action: defer setup to later."
                            ))
                            .font(OnboardingFonts.subheadline)
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
