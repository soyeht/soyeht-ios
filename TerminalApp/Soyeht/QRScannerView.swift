import SwiftUI
import SoyehtCore
import AVFoundation
import UIKit

// MARK: - QR Scanner View

struct QRScannerView: View {
    let showsCancel: Bool
    let activeHouseholdId: String?
    let nowProvider: () -> Date
    let onScanned: (QRScanResult, URL?) -> Void
    let onCancel: () -> Void

    @State private var showManualEntry = false
    @State private var manualToken = ""
    @State private var cameraPermissionDenied = false
    @State private var parseError: String?

    init(
        showsCancel: Bool,
        activeHouseholdId: String? = nil,
        nowProvider: @escaping () -> Date = { Date() },
        onScanned: @escaping (QRScanResult, URL?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.showsCancel = showsCancel
        self.activeHouseholdId = activeHouseholdId
        self.nowProvider = nowProvider
        self.onScanned = onScanned
        self.onCancel = onCancel
    }

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
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "common.accessibility.back",
                            defaultValue: "Back",
                            comment: "VoiceOver label for the back chevron in custom navigation headers."
                        )))
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
                if cameraPermissionDenied {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(SoyehtTheme.textComment)
                        Button(action: openAppSettings) {
                            Image(systemName: "gearshape")
                                .font(Typography.sansBody)
                                .foregroundColor(SoyehtTheme.accentGreen)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Open Settings"))
                    }
                    .frame(width: 220, height: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(SoyehtTheme.bgTertiary)
                    )
                } else {
                    CameraPreview(
                        onQRCodeDetected: handleQRCode,
                        onCameraDenied: {
                            cameraPermissionDenied = true
                            parseError = householdPairingMessage(for: .cameraPermissionDenied)
                        }
                    )
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

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
                guard let result = scanResult(
                    for: url,
                    fallbackError: String(localized: "qr.error.linkMustBeTheyos", comment: "Error shown when the URL isn't a valid Soyeht or theyOS deep link.")
                ) else { return }
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
        guard let result = scanResult(
            for: url,
            fallbackError: String(localized: "qr.error.qrMustBeTheyos", comment: "Error shown when the scanned QR isn't a valid Soyeht or theyOS deep link.")
        ) else { return }
        parseError = nil
        onScanned(result, url)
    }

    private func scanResult(for url: URL, fallbackError: String) -> QRScanResult? {
        switch QRScannerDispatcher.result(
            for: url,
            activeHouseholdId: activeHouseholdId,
            now: nowProvider()
        ) {
        case .success(let result):
            return result
        case .failure(let error):
            switch error {
            case .householdPairDeviceExpired:
                parseError = householdPairingMessage(for: .expiredQR)
                return nil
            case .householdPairDeviceInvalid:
                parseError = householdPairingMessage(for: .invalidQR)
                return nil
            case .householdPairDeviceSessionAlreadyActive:
                // SoyehtCore already ships a localized string for this exact
                // case (`firstOwnerAlreadyPaired`); reuse it instead of
                // minting a parallel one — keeps the in-app scanner and the
                // pair-service post-network branches saying the same thing
                // when the user hits the same wall via two different paths.
                parseError = householdPairingMessage(for: .firstOwnerAlreadyPaired)
                return nil
            case .machineJoin(let machineJoinError):
                parseError = JoinRequestConfirmationViewModel.localizedMessage(for: machineJoinError)
                return nil
            case .unsupportedDeepLink:
                parseError = fallbackError
                return nil
            }
        }
    }

    private func householdPairingMessage(for error: HouseholdPairingError) -> String {
        String(localized: String.LocalizationValue(error.localizationKey), bundle: SoyehtCoreResources.bundle)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

enum QRScannerDispatchError: Error, Equatable {
    case householdPairDeviceExpired
    case householdPairDeviceInvalid
    /// `pair-device` is the founding-owner ceremony — it is only valid when
    /// the iPhone has no `HouseholdSession` yet. Accepting one with an
    /// active session would silently overwrite the owner cert, drop APNS
    /// registration tied to the previous `personId`, and break gossip
    /// continuity for the existing household. Reject explicitly so the
    /// caller can surface a "you already belong to a household" message
    /// instead of pairing into oblivion.
    case householdPairDeviceSessionAlreadyActive
    case machineJoin(MachineJoinError)
    case unsupportedDeepLink
}

enum QRScannerDispatcher {
    static func result(
        for url: URL,
        activeHouseholdId: String?,
        now: Date
    ) -> Result<QRScanResult, QRScannerDispatchError> {
        if isHouseholdPairDeviceURL(url) {
            // Refuse pair-device URLs once a session exists. See the doc
            // on `householdPairDeviceSessionAlreadyActive` for the threat
            // model — short version: an attacker who can deliver a URL
            // (deep link, Camera-app QR, Messages preview, AirDrop) must
            // not be able to silently take over an already-paired device.
            if activeHouseholdId != nil {
                return .failure(.householdPairDeviceSessionAlreadyActive)
            }
            do {
                _ = try PairDeviceQR(url: url, now: now)
                return .success(.householdPairDevice(url: url))
            } catch PairDeviceQRError.expired {
                return .failure(.householdPairDeviceExpired)
            } catch {
                return .failure(.householdPairDeviceInvalid)
            }
        }

        if isHouseholdPairMachineURL(url) {
            guard let activeHouseholdId, !activeHouseholdId.isEmpty else {
                return .failure(.machineJoin(.hhMismatch))
            }
            do {
                let qr = try PairMachineQR(url: url, now: now)
                let envelope = JoinRequestEnvelope(
                    from: qr,
                    householdId: activeHouseholdId,
                    receivedAt: now
                )
                return .success(.householdPairMachine(envelope: envelope))
            } catch let error as PairMachineQRError {
                return .failure(.machineJoin(MachineJoinError(error)))
            } catch {
                return .failure(.machineJoin(.qrInvalid(reason: .schemaUnsupported(version: nil))))
            }
        }

        guard let result = QRScanResult.from(url: url) else {
            return .failure(.unsupportedDeepLink)
        }
        return .success(result)
    }

    private static func isHouseholdPairDeviceURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "soyeht"
            && components.host == "household"
            && components.path == "/pair-device"
    }

    private static func isHouseholdPairMachineURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "soyeht"
            && components.host == "household"
            && components.path == "/pair-machine"
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
    let onCameraDenied: () -> Void

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.onQRCodeDetected = onQRCodeDetected
        view.onCameraDenied = onCameraDenied
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.onQRCodeDetected = onQRCodeDetected
        uiView.onCameraDenied = onCameraDenied
    }
}

class CameraPreviewUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onQRCodeDetected: ((String) -> Void)?
    var onCameraDenied: (() -> Void)?
    private var captureSession: AVCaptureSession?
    private var hasDetected = false
    private var setupStarted = false
    private var cameraPermissionDenied = false
    private var didBecomeActiveObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        installLifecycleObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installLifecycleObserver()
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        captureSession?.stopRunning()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if captureSession == nil, !setupStarted {
            setupStarted = true
            setupCamera()
        }
        layer.sublayers?.first?.frame = bounds
    }

    private func installLifecycleObserver() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.retryCameraSetupIfNeeded()
        }
    }

    private func setupCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCameraSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.cameraPermissionDenied = false
                        self.configureCameraSession()
                    } else {
                        self.notifyCameraDenied()
                    }
                }
            }
        case .denied, .restricted:
            notifyCameraDenied()
        @unknown default:
            notifyCameraDenied()
        }
    }

    private func retryCameraSetupIfNeeded() {
        guard captureSession == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            guard cameraPermissionDenied || setupStarted else { return }
            setupStarted = false
            cameraPermissionDenied = false
            hasDetected = false
            setupStarted = true
            setupCamera()
        case .denied, .restricted:
            notifyCameraDenied()
        case .notDetermined:
            setupStarted = false
        @unknown default:
            notifyCameraDenied()
        }
    }

    private func configureCameraSession() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            notifyCameraDenied()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            notifyCameraDenied()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)

        captureSession = session
        cameraPermissionDenied = false
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func notifyCameraDenied() {
        cameraPermissionDenied = true
        onCameraDenied?()
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
