import SwiftUI
import SoyehtCore

/// Cena PB1 — "Onde você quer instalar Soyeht?" (FR-023).
/// Three options: Mac (enabled), Linux (coming soon, disabled), link for later.
struct InstallPickerView: View {
    let onMacSelected: () -> Void
    let onLater: () -> Void

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        heading

                        MoradorExplainerView()

                        optionCards
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                    .padding(.bottom, 40)
                }

                laterFooter
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource(
                "installPicker.title",
                defaultValue: "Onde você quer instalar Soyeht?",
                comment: "InstallPicker screen title asking where to install."
            ))
            .font(OnboardingFonts.headingLarge)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "installPicker.subtitle",
                defaultValue: "O Soyeht precisa de um computador como base.",
                comment: "InstallPicker subtitle explaining a computer is needed."
            ))
            .font(OnboardingFonts.callout)
            .foregroundColor(BrandColors.textMuted)
        }
    }

    private var optionCards: some View {
        VStack(spacing: 12) {
            InstallOptionCard(
                icon: "laptopcomputer",
                title: LocalizedStringResource(
                    "installPicker.option.mac",
                    defaultValue: "Meu Mac",
                    comment: "Install option: macOS computer."
                ),
                badge: nil,
                enabled: true,
                action: onMacSelected
            )

            InstallOptionCard(
                icon: "terminal",
                title: LocalizedStringResource(
                    "installPicker.option.linux",
                    defaultValue: "Meu Linux",
                    comment: "Install option: Linux computer."
                ),
                badge: LocalizedStringResource(
                    "installPicker.option.linux.badge",
                    defaultValue: "em breve",
                    comment: "Badge on the Linux option indicating it is not yet available."
                ),
                enabled: false,
                action: {}
            )
        }
    }

    private var laterFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .background(BrandColors.border)

            Button(action: onLater) {
                Text(LocalizedStringResource(
                    "installPicker.later",
                    defaultValue: "Pegar link depois",
                    comment: "Secondary action: get a download link later."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
                .padding(.vertical, 20)
            }
        }
        .background(BrandColors.surfaceDeep)
    }
}

// MARK: - InstallOptionCard

private struct InstallOptionCard: View {
    let icon: String
    let title: LocalizedStringResource
    let badge: LocalizedStringResource?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(enabled ? BrandColors.accentGreen : BrandColors.textMuted)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                Text(title)
                    .font(Font.body.weight(.medium))
                    .foregroundColor(enabled ? BrandColors.textPrimary : BrandColors.textMuted)

                Spacer()

                if let badge {
                    Text(badge)
                        .font(OnboardingFonts.caption2Bold)
                        .foregroundColor(BrandColors.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(BrandColors.border)
                        .clipShape(Capsule())
                }

                if enabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(BrandColors.textMuted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(BrandColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(BrandColors.border, lineWidth: 1)
            )
            .opacity(enabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(
            enabled
                ? Text(title)
                : Text(LocalizedStringResource(
                    "installPicker.option.unavailable",
                    defaultValue: "\(title), indisponível",
                    comment: "VoiceOver label for disabled install option."
                ))
        )
    }
}
