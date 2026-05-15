import SwiftUI
import SoyehtCore

/// Scene PB1 — "Where do you want to install Soyeht?" (FR-023).
/// Computer options route into the platform-specific setup path.
struct InstallPickerView: View {
    let onMacSelected: () -> Void
    let onLinuxSelected: () -> Void
    let onLater: () -> Void

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        heading

                        ResidentExplainerView()

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
                defaultValue: "Where do you want to install Soyeht?",
                comment: "InstallPicker screen title asking where to install."
            ))
            .font(OnboardingFonts.headingLarge)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "installPicker.subtitle",
                defaultValue: "Soyeht needs a computer as its base.",
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
                    defaultValue: "My Mac",
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
                    defaultValue: "My Linux",
                    comment: "Install option: Linux computer."
                ),
                badge: nil,
                enabled: true,
                action: onLinuxSelected
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
                    defaultValue: "Get link later",
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

// MARK: - LinuxPairingGuideView

struct LinuxPairingGuideView: View {
    let onScanPairingLink: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        stepsCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 36)
                    .padding(.bottom, 40)
                }

                footer
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text(LocalizedStringResource(
                        "linuxPairing.back",
                        defaultValue: "Back",
                        comment: "Back button from Linux setup to install picker."
                    ))
                    .font(OnboardingFonts.subheadline)
                }
                .foregroundColor(BrandColors.textMuted)
            }
            .buttonStyle(.plain)

            Image(systemName: "terminal")
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(BrandColors.accentGreen)
                .frame(width: 64, height: 64)
                .background(BrandColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(BrandColors.border, lineWidth: 1)
                )
                .accessibilityHidden(true)

            Text(LocalizedStringResource(
                "linuxPairing.title",
                defaultValue: "Connect your Linux computer",
                comment: "Title for Linux setup instructions."
            ))
            .font(OnboardingFonts.headingLarge)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "linuxPairing.subtitle",
                defaultValue: "Run the pairing command on Linux, then scan the QR code or paste the pairing link here.",
                comment: "Subtitle explaining Linux pairing."
            ))
            .font(OnboardingFonts.callout)
            .foregroundColor(BrandColors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            LinuxStepRow(
                index: 1,
                title: LocalizedStringResource(
                    "linuxPairing.step.install.title",
                    defaultValue: "Install and start theyOS",
                    comment: "Linux setup step title."
                ),
                detail: LocalizedStringResource(
                    "linuxPairing.step.install.detail",
                    defaultValue: "Use the installer or service configured for this Linux machine.",
                    comment: "Linux setup step detail."
                )
            )
            LinuxStepRow(
                index: 2,
                title: LocalizedStringResource(
                    "linuxPairing.step.pair.title",
                    defaultValue: "Run the pairing command",
                    comment: "Linux setup step title."
                ),
                detail: LocalizedStringResource(
                    "linuxPairing.step.pair.detail",
                    defaultValue: "Open a terminal on Linux and run `soyeht pair`.",
                    comment: "Linux setup step detail."
                )
            )
            LinuxStepRow(
                index: 3,
                title: LocalizedStringResource(
                    "linuxPairing.step.scan.title",
                    defaultValue: "Scan or paste the link",
                    comment: "Linux setup step title."
                ),
                detail: LocalizedStringResource(
                    "linuxPairing.step.scan.detail",
                    defaultValue: "Use the QR code or the theyos:// pairing link shown by the command.",
                    comment: "Linux setup step detail."
                )
            )
        }
        .padding(18)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(BrandColors.border, lineWidth: 1)
        )
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
                .background(BrandColors.border)

            Button(action: onScanPairingLink) {
                Text(LocalizedStringResource(
                    "linuxPairing.scanButton",
                    defaultValue: "Scan or paste pairing link",
                    comment: "Primary action to open QR scanner for Linux pairing."
                ))
                .font(OnboardingFonts.subheadline.weight(.semibold))
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(BrandColors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.InstallPicker.linuxScanPairingLinkButton)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(BrandColors.surfaceDeep)
    }
}

private struct LinuxStepRow: View {
    let index: Int
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: "\(index)")
                .font(OnboardingFonts.caption2Bold)
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(width: 28, height: 28)
                .background(BrandColors.accentGreen)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(OnboardingFonts.subheadline.weight(.semibold))
                    .foregroundColor(BrandColors.textPrimary)
                Text(detail)
                    .font(OnboardingFonts.caption)
                    .foregroundColor(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum OnboardingLaunchIntent {
    private static let qrScannerKey = "soyeht.onboarding.startInQRScanner"

    static func requestQRScanner(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: qrScannerKey)
    }

    static func consumeQRScannerRequest(defaults: UserDefaults = .standard) -> Bool {
        let requested = defaults.bool(forKey: qrScannerKey)
        defaults.removeObject(forKey: qrScannerKey)
        return requested
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
                    defaultValue: "\(title), unavailable",
                    comment: "VoiceOver label for disabled install option."
                ))
        )
    }
}
