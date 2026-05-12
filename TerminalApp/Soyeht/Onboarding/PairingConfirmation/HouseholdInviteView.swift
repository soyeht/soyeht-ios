import SwiftUI
import SoyehtCore

/// Scene P8 — iPhone discovers a newly named household via `_soyeht._tcp.` Bonjour.
/// Surfaces a notification card; tap-to-confirm starts the biometric flow.
struct HouseholdInviteView: View {
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
                            "pairing.householdInvite.host",
                            defaultValue: "created just now on \(hostLabel)",
                            comment: "Subtitle showing which Mac created the household."
                        ))
                        .font(OnboardingFonts.callout)
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button(action: onConfirm) {
                            Text(LocalizedStringResource(
                                "pairing.householdInvite.cta",
                                defaultValue: "Join as first resident",
                                comment: "CTA to begin pairing as the house's first member."
                            ))
                            .font(OnboardingFonts.bodyBold)
                            .foregroundColor(BrandColors.buttonTextOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(BrandColors.accentGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button(action: onDismiss) {
                            Text(LocalizedStringResource(
                                "pairing.householdInvite.dismiss",
                                defaultValue: "Not now",
                                comment: "Dismiss button on household invitation card."
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
            "pairing.householdInvite.a11y",
            defaultValue: "Home \(houseName) created on \(hostLabel). Tap to join as first resident.",
            comment: "VoiceOver summary for the household invitation card."
        )))
    }
}
