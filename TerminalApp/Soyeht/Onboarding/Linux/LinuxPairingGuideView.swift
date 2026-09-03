import SwiftUI
import SoyehtCore

// MARK: - LinuxPairingGuideView

/// The Linux answer to I2, and the last screen of the flow that was still
/// wearing the old palette: a flat card with a hairline border, blue numbered
/// discs and a rectangular accent button, sitting between two neo screens.
///
/// It is the same three steps; only the surfaces changed. The steps live in a
/// `NeoCard`, each number is a well sunk into it, and the two actions are the
/// same pill and link every other screen uses.
struct LinuxPairingGuideView: View {
    let onScanPairingLink: () -> Void
    let onBack: () -> Void

    @State private var showShareSheet = false

    private let palette = NeoPalette.cloud
    private static let theyOSInstallURL = URL(string: "https://github.com/soyeht/theyos")!

    var body: some View {
        OnboardingScaffold(palette: palette, onBack: onBack) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    stepsCard
                }
                .padding(.bottom, 8)
            }
        } actions: {
            VStack(spacing: 12) {
                Button(action: onScanPairingLink) {
                    Text(LocalizedStringResource(
                        "linuxPairing.scanButton",
                        defaultValue: "Scan or paste pairing link",
                        comment: "Primary action to open QR scanner for Linux pairing."
                    ))
                }
                .buttonStyle(NeoPillButtonStyle(.primary, palette: palette))
                .accessibilityIdentifier(AccessibilityID.InstallPicker.linuxScanPairingLinkButton)

                Button {
                    showShareSheet = true
                } label: {
                    Text(LocalizedStringResource(
                        "linuxPairing.shareInstallLink",
                        defaultValue: "Send install link to a computer",
                        comment: "Tertiary action on the Linux pairing guide. Opens a share sheet with the theyOS install URL so the user can send it to their Linux computer (email, AirDrop, messaging app) when theyOS is not yet installed."
                    ))
                }
                .buttonStyle(NeoLinkButtonStyle(palette: palette))
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [Self.theyOSInstallURL])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 72, height: 72)
                .neoRaised(palette, radius: NeoRadius.card, elevation: .card)
                .accessibilityHidden(true)

            Text(LocalizedStringResource(
                "linuxPairing.title",
                defaultValue: "Connect your Linux computer",
                comment: "Title for Linux setup instructions."
            ))
            .font(NeoFont.title)
            .foregroundStyle(palette.text)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "linuxPairing.subtitle",
                defaultValue: "Run the pairing command on Linux, then scan the QR code or paste the pairing link here.",
                comment: "Subtitle explaining Linux pairing."
            ))
            .font(NeoFont.body)
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepsCard: some View {
        NeoCard(palette: palette) {
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
        }
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

/// One step. The number is a well sunk into the card rather than a filled
/// disc floating on it: in this style depth is the only thing that separates
/// a label from a control, and a step number is neither.
private struct LinuxStepRow: View {
    let index: Int
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    @Environment(\.neoPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: "\(index)")
                .font(NeoFont.monoSmall)
                .foregroundStyle(palette.accent)
                .frame(width: 30, height: 30)
                .neoWell(palette, radius: 15)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(NeoFont.body)
                    .foregroundStyle(palette.text)
                Text(detail)
                    .font(NeoFont.caption)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Two one-shot requests the onboarding leaves for the main flow to pick up on
/// its next launch. They live here because this file is the last piece of the
/// old install-picker that anything still reaches.
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

    private static let skipSplashKey = "soyeht.onboarding.skipSplash"

    /// Set when the main flow is entered straight from the celebration. The
    /// splash exists to cover a cold launch; after "Open a terminal" there is
    /// nothing behind it to cover, and two seconds of logo between a tap and
    /// its result reads as the app hanging.
    static func requestSkipSplash(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: skipSplashKey)
    }

    static func consumeSkipSplashRequest(defaults: UserDefaults = .standard) -> Bool {
        let requested = defaults.bool(forKey: skipSplashKey)
        defaults.removeObject(forKey: skipSplashKey)
        return requested
    }
}
