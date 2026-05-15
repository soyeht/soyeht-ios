import SwiftUI
import SoyehtCore

/// Settings > About > How to recover my home (T111, FR-051).
/// Surfaces the same recovery explanation as RecoveryMessageView + safety footer.
struct HowToRecoverView: View {
    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 24)

                    KeyHandoffMetaphorView(onComplete: {})

                    VStack(spacing: 14) {
                        Text(LocalizedStringResource(
                            "howToRecover.title",
                            defaultValue: "How your home recovers",
                            comment: "Settings How-to-recover screen title."
                        ))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "howToRecover.body",
                            defaultValue: "If you lose your iPhone, another Mac that's already part of your home can recover access. Your keys stay distributed, so no single device is a point of failure.",
                            comment: "How-to-recover body explanation."
                        ))
                        .font(.system(size: 16))
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)

                    safetyFooter
                        .padding(.horizontal, 32)

                    Spacer(minLength: 40)
                }
            }
        }
        .navigationTitle(LocalizedStringResource(
            "howToRecover.nav.title",
            defaultValue: "Home recovery",
            comment: "Navigation title for How-to-recover settings screen."
        ))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }

    private var safetyFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(BrandColors.accentGreen)
                .accessibilityHidden(true)

            Text(LocalizedStringResource(
                "howToRecover.safetyNote",
                defaultValue: "Dismissing this again is safe. You can review this explanation whenever you want.",
                comment: "Safety reassurance footer on how-to-recover screen. FR-051."
            ))
            .font(.system(size: 13))
            .foregroundColor(BrandColors.textMuted)
        }
        .padding(14)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(BrandColors.border, lineWidth: 1)
        )
    }
}
