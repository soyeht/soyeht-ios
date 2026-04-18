import SwiftUI
import SoyehtCore
import AVFoundation
import UIKit

// MARK: - QR Scanner View

struct QRScannerView: View {
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
                    if SessionStore.shared.pairedServers.isEmpty {
                        Spacer()
                    } else {
                        Button(action: onCancel) {
                            HStack(spacing: 0) {
                                Text("< ")
                                    .foregroundColor(SoyehtTheme.accentGreen)
                                Text("soyeht")
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Scanner View

    private var scannerView: some View {
        VStack(spacing: 24) {
            // Section label
            Text("// scan qr code")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)

            Text("scan the qr code to get started")
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
                    Text("theyos:// protocol")
                        .font(Typography.monoBodySemi)
                        .foregroundColor(SoyehtTheme.textPrimary)
                }

                HStack(spacing: 6) {
                    Text("$")
                        .font(Typography.monoLabelBold)
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("the qr code contains your auth token and host address")
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
                Text("or")
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
                    Text(">>")
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("paste link")
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

            Text("camera access required for qr scanning")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textComment)
                .padding(.bottom, 20)

            if let error = parseError {
                Text(error)
                    .font(Typography.monoSmall)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Manual Entry View

    private var manualEntryView: some View {
        VStack(spacing: 24) {
            Text("// paste link")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)

            Text("paste the link you received to connect")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LINK")
                        .font(Typography.monoSectionLabel)
                        .foregroundColor(SoyehtTheme.textComment)
                    TextField("theyos://connect?token=...&host=...", text: $manualToken)
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
                    parseError = "paste a theyos:// link first"
                    return
                }
                guard let url = URL(string: input) else {
                    parseError = "invalid link format"
                    return
                }
                guard let result = QRScanResult.from(url: url) else {
                    parseError = "link must be a theyos:// deep link with token and host"
                    return
                }
                parseError = nil
                onScanned(result, url)
            }) {
                Text("connect")
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
            .opacity(manualToken.isEmpty ? 0.4 : 1.0)

            if let error = parseError {
                Text(error)
                    .font(Typography.monoSmall)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
            }

            if !isSimulator {
                Button(action: {
                    parseError = nil
                    showManualEntry = false
                }) {
                    Text("back to scanner")
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
            parseError = "invalid qr link format"
            return
        }
        guard let result = QRScanResult.from(url: url) else {
            parseError = "qr code must be a theyos:// deep link with token and host"
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
