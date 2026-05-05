import SwiftUI
import SoyehtCore
import AVFoundation
import UIKit

// MARK: - QR Scanner View

struct QRScannerView: View {
    let showsCancel: Bool
    let onScanned: (QRScanResult, URL?) -> Void
    let onCancel: () -> Void

    @State private var showManualEntry = false
    @State private var manualToken = ""
    @State private var cameraPermissionDenied = false
    @State private var parseError: String?

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    if !showsCancel {
                        Spacer()
                    } else {
                        Button(action: onCancel) {
                            HStack(spacing: 0) {
                                Text(verbatim: "< ")
                                    .foregroundColor(SoyehtTheme.accentGreen)
                                Text(verbatim: "soyeht")
                                    .foregroundColor(SoyehtTheme.textPrimary)
                            }
                            .font(Typography.monoPageTitle)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)

                if showManualEntry {
                    manualEntryView
                } else {
                    scannerView
                }
            }
        }
        .preferredColorScheme(SoyehtTheme.preferredColorScheme)
    }

    // MARK: - Scanner View

    private var scannerView: some View {
        VStack(spacing: 24) {
            // Section label
            Text("qr.section.scan")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)

            Text("qr.hint")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Camera viewfinder
            ZStack {
                CameraPreview(onQRCodeDetected: handleQRCode)
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Green corner brackets
                ViewfinderOverlay()
                    .frame(width: 240, height: 240)
            }
            .padding(.vertical, 20)

            // Protocol label
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(Typography.sansBody)
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("qr.protocol.label")
                        .font(Typography.monoBodySemi)
                        .foregroundColor(SoyehtTheme.textPrimary)
                }

                HStack(spacing: 6) {
                    Text(verbatim: "$")
                        .font(Typography.monoLabelBold)
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("qr.protocol.hint")
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
            }

            Spacer()

            // Divider
            HStack {
                Rectangle()
                    .fill(SoyehtTheme.bgCardBorder)
                    .frame(height: 1)
                Text("qr.divider.or")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textComment)
                Rectangle()
                    .fill(SoyehtTheme.bgCardBorder)
                    .frame(height: 1)
            }
            .padding(.horizontal, 40)

            // Manual entry button
            Button(action: {
                parseError = nil
                manualToken = (UIPasteboard.general.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                showManualEntry = true
            }) {
                HStack(spacing: 8) {
                    Text(verbatim: ">>")
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("qr.action.pasteLink")
                        .foregroundColor(SoyehtTheme.textPrimary)
                }
                .font(Typography.monoBodyMedium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.QRScanner.pasteManualButton)
            .padding(.horizontal, 20)

            Text("qr.permission.cameraRequired")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textComment)
                .padding(.bottom, 20)

            if let error = parseError {
                Text(error)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.accentRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Manual Entry View

    private var manualEntryView: some View {
        VStack(spacing: 24) {
            Text("qr.section.pasteLink")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)

            Text("qr.pasteLink.hint")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("qr.label.link")
                        .font(Typography.monoSectionLabel)
                        .foregroundColor(SoyehtTheme.textComment)
                    TextField("qr.textField.placeholder", text: $manualToken)
                        .font(Typography.monoBody)
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .padding(12)
                        .accessibilityIdentifier(AccessibilityID.QRScanner.tokenTextField)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(SoyehtTheme.bgTertiary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                                )
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

            }
            .padding(.horizontal, 20)

            Button(action: {
                let input = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !input.isEmpty else {
                    parseError = String(localized: "qr.error.pasteFirst", comment: "Error shown when tapping Connect with no link pasted.")
                    return
                }
                guard let url = URL(string: input) else {
                    parseError = String(localized: "qr.error.invalidFormat", comment: "Error shown when the pasted text isn't a valid URL.")
                    return
                }
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   components.scheme == "theyos",
                   components.host == "connect",
                   components.queryItems?.contains(where: { $0.name == "local_handoff" && $0.value == "mac_local" }) == true {
                    parseError = nil
                    onScanned(.connect(token: "", host: ""), url)
                    return
                }
                guard let result = QRScanResult.from(url: url) else {
                    parseError = String(localized: "qr.error.linkMustBeTheyos", comment: "Error shown when the URL isn't a valid theyos:// deep link with token+host.")
                    return
                }
                parseError = nil
                onScanned(result, url)
            }) {
                Text("qr.button.connect")
                    .font(Typography.monoBodySemi)
                    .foregroundColor(SoyehtTheme.buttonTextOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(SoyehtTheme.accentGreen)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.QRScanner.connectButton)
            .padding(.horizontal, 20)

            if let error = parseError {
                Text(error)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.accentRed)
                    .padding(.horizontal, 20)
            }

            if !isSimulator {
                Button(action: {
                    parseError = nil
                    showManualEntry = false
                }) {
                    Text("qr.button.backToScanner")
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.accentGreen)
                }
            }

            Spacer()
        }
    }

    // MARK: - QR Code Handler

    private func handleQRCode(_ code: String) {
        guard let url = URL(string: code) else {
            parseError = String(localized: "qr.error.invalidQR", comment: "Error shown when the scanned QR is not a valid URL.")
            return
        }
        // Fase 2 local-handoff QR (`theyos://connect?local_handoff=mac_local&…`)
        // does not carry the legacy `token`/`host` pair, so `QRScanResult.from`
        // would reject it. Matches the deep-link path in
        // `SSHLoginView.handleIncomingDeepLink`: pass a stub result; the
        // downstream handler short-circuits on the URL.
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.scheme == "theyos",
           components.host == "connect",
           components.queryItems?.contains(where: { $0.name == "local_handoff" && $0.value == "mac_local" }) == true {
            parseError = nil
            onScanned(.connect(token: "", host: ""), url)
            return
        }
        guard let result = QRScanResult.from(url: url) else {
            parseError = String(localized: "qr.error.qrMustBeTheyos", comment: "Error shown when the scanned QR isn't a valid theyos:// deep link.")
            return
        }
        parseError = nil
        onScanned(result, url)
    }
}

// MARK: - Viewfinder Overlay

private struct ViewfinderOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let cornerLength: CGFloat = 30
            let lineWidth: CGFloat = 3

            Path { path in
                // Top-left
                path.move(to: CGPoint(x: 0, y: cornerLength))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: cornerLength, y: 0))

                // Top-right
                path.move(to: CGPoint(x: size.width - cornerLength, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: cornerLength))

                // Bottom-right
                path.move(to: CGPoint(x: size.width, y: size.height - cornerLength))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.addLine(to: CGPoint(x: size.width - cornerLength, y: size.height))

                // Bottom-left
                path.move(to: CGPoint(x: cornerLength, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height - cornerLength))
            }
            .stroke(SoyehtTheme.accentGreen, lineWidth: lineWidth)
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

struct CameraPreview: UIViewRepresentable {
    let onQRCodeDetected: (String) -> Void

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.onQRCodeDetected = onQRCodeDetected
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

class CameraPreviewUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onQRCodeDetected: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var hasDetected = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if captureSession == nil {
            setupCamera()
        }
        layer.sublayers?.first?.frame = bounds
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasDetected,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        hasDetected = true
        captureSession?.stopRunning()
        onQRCodeDetected?(value)
    }
}
