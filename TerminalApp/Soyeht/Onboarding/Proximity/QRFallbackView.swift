import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import SoyehtCore

/// Cena PB3b — URL `soyeht.com/mac` + QR code + ShareSheet fallback (T068, FR-025).
/// Shown when AirDrop fails or is unavailable. Provides QR the user can scan on Mac's webcam.
struct QRFallbackView: View {
    let downloadToken: String
    let onDismiss: () -> Void

    private var downloadURL: URL {
        // soyeht.com/mac?token=<token> — token lets the Mac pre-authorize on landing.
        URL(string: "https://soyeht.com/mac?token=\(downloadToken)") ?? URL(string: "https://soyeht.com/mac")!
    }

    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                dismissBar

                ScrollView {
                    VStack(spacing: 28) {
                        heading

                        qrCard

                        shareButton
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
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(BrandColors.textMuted)
            }
            .accessibilityLabel(Text(LocalizedStringResource(
                "qrFallback.dismiss.a11y",
                defaultValue: "Fechar",
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
                defaultValue: "Escaneie no Mac",
                comment: "QR fallback screen title: instructs user to scan QR on Mac."
            ))
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(BrandColors.textPrimary)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "qrFallback.subtitle",
                defaultValue: "Aponte a câmera do Mac para este código e o download começará automaticamente.",
                comment: "QR fallback subtitle explaining how to use the QR code."
            ))
            .font(.system(size: 15))
            .foregroundColor(BrandColors.textMuted)
            .multilineTextAlignment(.center)
        }
    }

    private var qrCard: some View {
        VStack(spacing: 16) {
            if let qrImage = generateQRCode(from: downloadURL.absoluteString) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "qrFallback.qr.a11y",
                        defaultValue: "Código QR para download do Soyeht em soyeht.com/mac",
                        comment: "VoiceOver description of the QR code."
                    )))
            } else {
                qrPlaceholder
            }

            Text(verbatim: downloadURL.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityHidden(true)
        }
        .padding(20)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var qrPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(BrandColors.border)
                .frame(width: 220, height: 220)
            ProgressView()
                .tint(BrandColors.textMuted)
        }
    }

    private var shareButton: some View {
        Button(action: { showShareSheet = true }) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17))
                    .accessibilityHidden(true)
                Text(LocalizedStringResource(
                    "qrFallback.share",
                    defaultValue: "Compartilhar link",
                    comment: "Share sheet button for the download URL."
                ))
                .font(.system(size: 17, weight: .semibold))
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

    // MARK: - QR Generation

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
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
