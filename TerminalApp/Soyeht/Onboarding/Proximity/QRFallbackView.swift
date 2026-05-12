import SwiftUI
import UIKit
import SoyehtCore

/// Scene PB3b — direct macOS download link + ShareSheet fallback (T068, FR-025).
/// Shown when AirDrop fails or is unavailable. Provides a link the user can send
/// to the Mac without assuming the Mac has a camera.
struct QRFallbackView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    private let downloadURL = URL(string: "https://github.com/soyeht/soyeht-ios/releases/latest/download/Soyeht.dmg")!

    @State private var showShareSheet = false
    @State private var didCopyLink = false

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                dismissBar

                ScrollView {
                    VStack(spacing: 28) {
                        heading

                        linkCard

                        shareButton

                        copyButton

                        continueButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [downloadURL])
        }
    }

    private var dismissBar: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(BrandColors.textMuted)
            }
            .accessibilityLabel(Text(LocalizedStringResource(
                "qrFallback.dismiss.a11y",
                defaultValue: "Close",
                comment: "VoiceOver label for dismiss button."
            )))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var heading: some View {
        VStack(spacing: 10) {
            Text(LocalizedStringResource(
                "qrFallback.title",
                defaultValue: "Open on your Mac",
                comment: "Fallback screen title: asks user to open the download link on Mac."
            ))
            .font(OnboardingFonts.heading)
            .foregroundColor(BrandColors.textPrimary)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "qrFallback.subtitle",
                defaultValue: "Send this link to your Mac. It downloads Soyeht directly, with no camera needed.",
                comment: "Fallback subtitle explaining how to use the Mac download link."
            ))
            .font(OnboardingFonts.subheadline)
            .foregroundColor(BrandColors.textMuted)
            .multilineTextAlignment(.center)
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(BrandColors.accentGreen)
                    .accessibilityHidden(true)
                Text(LocalizedStringResource(
                    "qrFallback.linkLabel",
                    defaultValue: "Mac link",
                    comment: "Label above the direct macOS download link."
                ))
                .font(OnboardingFonts.bodyBold)
                .foregroundColor(BrandColors.textPrimary)
            }
            Text(verbatim: downloadURL.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(20)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(BrandColors.border, lineWidth: 1)
        )
    }

    private var shareButton: some View {
        Button(action: { showShareSheet = true }) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17))
                    .accessibilityHidden(true)
                Text(LocalizedStringResource(
                    "qrFallback.share",
                    defaultValue: "Share link",
                    comment: "Share sheet button for the download URL."
                ))
                .font(OnboardingFonts.bodyBold)
            }
            .foregroundColor(BrandColors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BrandColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(BrandColors.border, lineWidth: 1)
            )
        }
    }

    private var copyButton: some View {
        Button(action: copyDownloadLink) {
            HStack(spacing: 10) {
                Image(systemName: didCopyLink ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityHidden(true)
                Text(didCopyLink
                     ? LocalizedStringResource("qrFallback.copy.done", defaultValue: "Link copied", comment: "Copy link button after copying.")
                     : LocalizedStringResource("qrFallback.copy", defaultValue: "Copy link", comment: "Copy link button."))
                .font(OnboardingFonts.bodyBold)
            }
            .foregroundColor(BrandColors.accentGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            Text(LocalizedStringResource(
                "qrFallback.continue",
                defaultValue: "I opened it on my Mac",
                comment: "CTA after the user has opened the Mac app from the shared download link."
            ))
            .font(OnboardingFonts.bodyBold)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BrandColors.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func copyDownloadLink() {
        UIPasteboard.general.string = downloadURL.absoluteString
        didCopyLink = true
    }
}

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
