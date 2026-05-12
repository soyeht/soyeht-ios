import SwiftUI
import SoyehtCore

/// Shown instead of the carousel when a restore-from-backup is detected (T087a, FR-122).
/// "You've used Soyeht before. Let's reconnect to your home."
struct RestoredFromBackupView: View {
    let onReconnect: () -> Void

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 32) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(BrandColors.accentGreen)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text(LocalizedStringResource(
                        "restoredFromBackup.title",
                        defaultValue: "You've used Soyeht before.",
                        comment: "Restored-from-backup screen title."
                    ))
                    .font(OnboardingFonts.heading)
                    .foregroundColor(BrandColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                    Text(LocalizedStringResource(
                        "restoredFromBackup.subtitle",
                        defaultValue: "Let's reconnect to your home.",
                        comment: "Restored-from-backup subtitle. Friendly, reassuring tone."
                    ))
                    .font(OnboardingFonts.callout)
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                }

                Button(action: onReconnect) {
                    Text(LocalizedStringResource(
                        "restoredFromBackup.cta",
                        defaultValue: "Reconnect",
                        comment: "CTA to reconnect with an existing household after restore."
                    ))
                    .font(OnboardingFonts.bodyBold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 40)
            }
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }
}
