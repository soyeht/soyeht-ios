import SwiftUI
import SoyehtCore

// MARK: - LinuxPairingGuideView

struct LinuxPairingGuideView: View {
    let onScanPairingLink: () -> Void
    let onBack: () -> Void

    @State private var showShareSheet = false

    private static let theyOSInstallURL = URL(string: "https://github.com/soyeht/theyos")!

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
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [Self.theyOSInstallURL])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward")
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

            Button {
                showShareSheet = true
            } label: {
                Text(LocalizedStringResource(
                    "linuxPairing.shareInstallLink",
                    defaultValue: "Send install link to a computer",
                    comment: "Tertiary action on the Linux pairing guide. Opens a share sheet with the theyOS install URL so the user can send it to their Linux computer (email, AirDrop, messaging app) when theyOS is not yet installed."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.accentGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 12)

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
            .padding(.bottom, 18)
        }
        .background(BrandColors.surfaceDeep)
    }
}

// MARK: - ShareSheet

/// Shared by the Linux guide, the "is it on your Mac?" question and the
/// radar's "Get the link": three screens hand out the same macOS build.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
