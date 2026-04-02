import SwiftUI
import AVFoundation

// MARK: - QR Scanner View

struct QRScannerView: View {
    let onScanned: (QRScanResult) -> Void
    let onCancel: () -> Void

    @State private var showManualEntry = false
    @State private var manualToken = ""
    @State private var manualHost = ""
    @State private var cameraPermissionDenied = false

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
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .medium))
                                Text("connect")
                                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(SoyehtTheme.textSecondary)
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
                .font(SoyehtTheme.labelFont)
                .foregroundColor(SoyehtTheme.textComment)

            Text("scan the qr code to get started")
                .font(SoyehtTheme.smallMono)
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
                        .font(.system(size: 14))
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("theyos:// protocol")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textPrimary)
                }

                HStack(spacing: 6) {
                    Text("$")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("the qr code contains your auth token and host address")
                        .font(SoyehtTheme.smallMono)
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
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textComment)
                Rectangle()
                    .fill(SoyehtTheme.bgCardBorder)
                    .frame(height: 1)
            }
            .padding(.horizontal, 40)

            // Manual entry button
            Button(action: { showManualEntry = true }) {
                HStack(spacing: 8) {
                    Text(">>")
                        .foregroundColor(SoyehtTheme.accentGreen)
                    Text("enter token manually")
                        .foregroundColor(SoyehtTheme.textPrimary)
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)

            Text("camera access required for qr scanning")
                .font(SoyehtTheme.smallMono)
                .foregroundColor(SoyehtTheme.textComment)
                .padding(.bottom, 20)
        }
    }

    // MARK: - Manual Entry View

    private var manualEntryView: some View {
        VStack(spacing: 24) {
            Text("// enter token manually")
                .font(SoyehtTheme.labelFont)
                .foregroundColor(SoyehtTheme.textComment)

            Text("enter the token and host address to connect")
                .font(SoyehtTheme.smallMono)
                .foregroundColor(SoyehtTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HOST")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textComment)
                    TextField("<host-2>.<tailnet>.ts.net", text: $manualHost)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .padding(12)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("TOKEN")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textComment)
                    TextField("paste your token here", text: $manualToken)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .padding(12)
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
                }
            }
            .padding(.horizontal, 20)

            Button(action: {
                let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty, !host.isEmpty else { return }
                onScanned(.pair(token: token, host: host))
            }) {
                Text("connect")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(SoyehtTheme.buttonTextOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(SoyehtTheme.accentGreen)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .opacity(manualToken.isEmpty || manualHost.isEmpty ? 0.4 : 1.0)

            if !isSimulator {
                Button(action: { showManualEntry = false }) {
                    Text("back to scanner")
                        .font(SoyehtTheme.smallMono)
                        .foregroundColor(SoyehtTheme.accentGreen)
                }
            }

            Spacer()
        }
    }

    // MARK: - QR Code Handler

    private func handleQRCode(_ code: String) {
        guard let components = URLComponents(string: code),
              components.scheme == "theyos",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              let host = components.queryItems?.first(where: { $0.name == "host" })?.value else {
            return
        }
        switch components.host {
        case "pair":
            onScanned(.pair(token: token, host: host))
        case "connect":
            onScanned(.connect(token: token, host: host))
        default:
            return
        }
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
