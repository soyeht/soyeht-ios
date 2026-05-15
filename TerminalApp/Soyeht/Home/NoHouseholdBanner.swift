import SwiftUI
import SoyehtCore

/// T102 — persistent banner shown when no household is configured and the user
/// previously deferred setup via LaterParkingLotView (FR-030).
/// Tapping navigates to ProximityQuestionView to resume setup.
struct NoHouseholdBanner: View {
    let onSetupNow: () -> Void

    var body: some View {
        Button(action: onSetupNow) {
            HStack(spacing: 12) {
                Image(systemName: "house.badge.plus")
                    .font(.system(size: 20))
                    .foregroundColor(BrandColors.accentGreen)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource(
                        "noHouseholdBanner.title",
                        defaultValue: "Your home isn't set up yet",
                        comment: "NoHouseholdBanner primary line. Shown when household setup was deferred."
                    ))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(BrandColors.textPrimary)

                    Text(LocalizedStringResource(
                        "noHouseholdBanner.subtitle",
                        defaultValue: "Tap to set it up now",
                        comment: "NoHouseholdBanner secondary CTA line."
                    ))
                    .font(.system(size: 12))
                    .foregroundColor(BrandColors.textMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(BrandColors.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(BrandColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(BrandColors.accentGreen.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringResource(
            "noHouseholdBanner.a11y",
            defaultValue: "Your home isn't set up yet. Tap to set it up now.",
            comment: "VoiceOver label for NoHouseholdBanner."
        )))
        .accessibilityHint(Text(LocalizedStringResource(
            "noHouseholdBanner.a11yHint",
            defaultValue: "Opens the setup assistant",
            comment: "VoiceOver hint for NoHouseholdBanner."
        )))
    }
}
