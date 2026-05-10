import SwiftUI
import SoyehtCore

/// T102 — persistent banner shown when no casa is configured and the user
/// previously deferred setup via LaterParkingLotView (FR-030).
/// Tapping navigates to ProximityQuestionView to resume setup.
struct NoCasaBanner: View {
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
                        "noCasaBanner.title",
                        defaultValue: "Sua casa ainda não está configurada",
                        comment: "NoCasaBanner primary line. Shown when household setup was deferred."
                    ))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(BrandColors.textPrimary)

                    Text(LocalizedStringResource(
                        "noCasaBanner.subtitle",
                        defaultValue: "Toque para configurar agora",
                        comment: "NoCasaBanner secondary CTA line."
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
            "noCasaBanner.a11y",
            defaultValue: "Sua casa ainda não está configurada. Toque para configurar agora.",
            comment: "VoiceOver label for NoCasaBanner."
        )))
        .accessibilityHint(Text(LocalizedStringResource(
            "noCasaBanner.a11yHint",
            defaultValue: "Abre o assistente de configuração",
            comment: "VoiceOver hint for NoCasaBanner."
        )))
    }
}
