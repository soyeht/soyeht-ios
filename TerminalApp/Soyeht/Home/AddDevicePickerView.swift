import SwiftUI
import SoyehtCore

/// Sheet presented from InstanceList's "+" so users adding a second device
/// see a Linux pairing guide before being thrown into a raw QR scanner.
/// US-F: closes the "I have a Mac, how do I add a Linux?" discovery gap.
struct AddDevicePickerView: View {
    /// Called when the user wants to land in the raw QR/paste-link scanner.
    /// SSHLoginView dismisses the sheet and flips `appState` to `.qrScanner`.
    let onScanPairingLink: () -> Void
    /// Called when the user dismisses the sheet without picking anything.
    let onDismiss: () -> Void

    private enum Screen {
        case picker
        case linuxGuide
    }

    @State private var screen: Screen = .picker

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            switch screen {
            case .picker:
                pickerContent
            case .linuxGuide:
                LinuxPairingGuideView(
                    onScanPairingLink: onScanPairingLink,
                    onBack: { screen = .picker }
                )
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            dismissBar
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heading
                    optionCards
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
    }

    private var dismissBar: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(BrandColors.textMuted)
            }
            .accessibilityLabel(Text(LocalizedStringResource(
                "addDevice.dismiss.a11y",
                defaultValue: "Close",
                comment: "VoiceOver label for the dismiss button on the Add Device picker."
            )))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource(
                "addDevice.title",
                defaultValue: "Add a device",
                comment: "Add Device picker title shown when the user taps the + button on the instance list."
            ))
            .font(OnboardingFonts.headingLarge)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "addDevice.subtitle",
                defaultValue: "Connect a Linux machine, or use an existing pairing link.",
                comment: "Add Device picker subtitle explaining the two ways to add a second machine."
            ))
            .font(OnboardingFonts.callout)
            .foregroundColor(BrandColors.textMuted)
        }
    }

    private var optionCards: some View {
        VStack(spacing: 12) {
            Button(action: { screen = .linuxGuide }) {
                AddDeviceOptionCard(
                    icon: "terminal",
                    title: LocalizedStringResource(
                        "addDevice.option.linux",
                        defaultValue: "Linux machine",
                        comment: "Add Device option leading to the Linux pairing guide."
                    ),
                    detail: LocalizedStringResource(
                        "addDevice.option.linux.detail",
                        defaultValue: "Step-by-step guide to run soyeht pair on Linux.",
                        comment: "Detail line for the Linux machine option on the Add Device picker."
                    )
                )
            }
            .buttonStyle(.plain)

            Button(action: onScanPairingLink) {
                AddDeviceOptionCard(
                    icon: "qrcode.viewfinder",
                    title: LocalizedStringResource(
                        "addDevice.option.scan",
                        defaultValue: "I have a pairing link",
                        comment: "Add Device option for users who already have a QR or theyos:// link."
                    ),
                    detail: LocalizedStringResource(
                        "addDevice.option.scan.detail",
                        defaultValue: "Scan a QR code or paste a theyos:// link.",
                        comment: "Detail line for the scan-or-paste option on the Add Device picker."
                    )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AddDeviceOptionCard: View {
    let icon: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(BrandColors.accentGreen)
                .frame(width: 32, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Font.body.weight(.medium))
                    .foregroundColor(BrandColors.textPrimary)
                Text(detail)
                    .font(OnboardingFonts.caption)
                    .foregroundColor(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(BrandColors.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(BrandColors.border, lineWidth: 1)
        )
    }
}
