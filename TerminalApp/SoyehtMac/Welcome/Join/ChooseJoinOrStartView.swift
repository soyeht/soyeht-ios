import SwiftUI
import SoyehtCore

struct ChooseJoinOrStartView: View {
    let onJoinExisting: () -> Void
    let onStartNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            badge
                .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 14) {
                Text(LocalizedStringResource(
                    "welcome.joinChoice.title",
                    defaultValue: "Welcome to Soyeht.",
                    comment: "Mac welcome title before choosing whether to join an existing Soyeht or start a new one."
                ))
                .font(MacTypography.Fonts.Display.heroTitle)
                .foregroundColor(BrandColors.textPrimary)

                Text(LocalizedStringResource(
                    "welcome.joinChoice.subtitle",
                    defaultValue: "Use this Mac with a Soyeht you already control, or start a new one here.",
                    comment: "Mac welcome subtitle explaining the two setup choices."
                ))
                .font(MacTypography.Fonts.Display.heroSubtitle)
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: onJoinExisting) {
                    JoinChoiceRow(
                        icon: "qrcode",
                        title: LocalizedStringResource(
                            "welcome.joinChoice.existing.title",
                            defaultValue: "Join existing Soyeht",
                            comment: "Primary choice on Mac welcome screen for joining an existing Soyeht."
                        ),
                        detail: LocalizedStringResource(
                            "welcome.joinChoice.existing.detail",
                            defaultValue: "Show a QR code that a paired iPhone can scan.",
                            comment: "Detail text for the join-existing-Soyeht choice."
                        ),
                        isPrimary: true
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button(action: onStartNew) {
                    JoinChoiceRow(
                        icon: "plus.circle",
                        title: LocalizedStringResource(
                            "welcome.joinChoice.start.title",
                            defaultValue: "Start a new Soyeht",
                            comment: "Secondary choice on Mac welcome screen for creating a new Soyeht on this Mac."
                        ),
                        detail: LocalizedStringResource(
                            "welcome.joinChoice.start.detail",
                            defaultValue: "Create a new Soyeht with this Mac as the first server.",
                            comment: "Detail text for the start-new-Soyeht choice."
                        ),
                        isPrimary: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var badge: some View {
        Text(LocalizedStringResource(
            "welcome.joinChoice.badge",
            defaultValue: "Choose setup",
            comment: "Badge on Mac welcome choice screen."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.buttonTextOnAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.accentGreen)
        .clipShape(Capsule())
    }
}

private struct JoinChoiceRow: View {
    let icon: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let isPrimary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(isPrimary ? BrandColors.buttonTextOnAccent : BrandColors.accentGreen)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(isPrimary ? BrandColors.buttonTextOnAccent : BrandColors.textPrimary)
                Text(detail)
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(isPrimary ? BrandColors.buttonTextOnAccent.opacity(0.82) : BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chevron.forward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isPrimary ? BrandColors.buttonTextOnAccent.opacity(0.8) : BrandColors.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPrimary ? BrandColors.accentGreen : BrandColors.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPrimary ? Color.clear : BrandColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
