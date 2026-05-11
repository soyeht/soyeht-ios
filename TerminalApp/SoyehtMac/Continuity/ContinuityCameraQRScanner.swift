import Foundation
import AVFoundation
import Vision
import Combine

/// Mac-webcam QR scanner for Caso B fallback (T072, FR-130, research R9, R20).
///
/// State machine: searching → acquiring → confirmed.
/// `searching`: camera started, scanning in progress.
/// `acquiring`: first barcode contour detected; scan-line animation running.
/// `confirmed`: QR code fully decoded; fires `onResult` once.
public final class ContinuityCameraQRScanner: NSObject, ObservableObject {
    public enum ScanState: Equatable, Sendable {
        case searching
        case acquiring
        case confirmed(String)
    }

    @Published public private(set) var state: ScanState = .searching

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var captureLayer: AVCaptureVideoPreviewLayer?
    private var hasConfirmed = false

    private let sessionQueue = DispatchQueue(label: "com.soyeht.continuity-camera")

    // MARK: - Lifecycle

    public func start() {
        sessionQueue.async { [weak self] in self?.configureAndStart() }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    public func previewLayer(for bounds: CGRect) -> AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        if captureLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            captureLayer = layer
        }
        captureLayer?.frame = bounds
        return captureLayer
    }

    // MARK: - Private

    private func configureAndStart() {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = bestCamera() else { return }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        captureSession = session
        videoOutput = output
        session.startRunning()
    }

    private func bestCamera() -> AVCaptureDevice? {
        // Prefer Continuity Camera (iPhone as webcam) over built-in; fall back gracefully.
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )
        return discoverySession.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func process(sampleBuffer: CMSampleBuffer) {
        guard !hasConfirmed else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest { [weak self] req, error in
            guard let self, error == nil else { return }
            self.handleBarcodeResults(req.results as? [VNBarcodeObservation] ?? [])
        }
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func handleBarcodeResults(_ results: [VNBarcodeObservation]) {
        guard !hasConfirmed else { return }

        if results.isEmpty { return }

        Task { @MainActor [weak self] in
            guard let self, !self.hasConfirmed else { return }

            if self.state == .searching {
                self.state = .acquiring
            }

            if let barcode = results.first,
               let payload = barcode.payloadStringValue,
               !payload.isEmpty {
                self.hasConfirmed = true
                self.state = .confirmed(payload)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ContinuityCameraQRScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Task { @MainActor [weak self] in self?.process(sampleBuffer: sampleBuffer) }
    }
}
