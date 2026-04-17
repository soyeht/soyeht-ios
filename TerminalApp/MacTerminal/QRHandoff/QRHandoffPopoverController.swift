import AppKit
import SoyehtCore

/// Popover content for the per-pane "Continue on iPhone" QR hand-off.
/// Lifted out of the legacy `SoyehtInstanceViewController` so any pane can
/// present it from its header QR button.
///
/// Shows a server-rendered QR image, a countdown timer, and polls every 2s
/// until the server reports the token has been redeemed — at which point the
/// popover flips to a "Conectado" checkmark and closes itself 800ms later.
@MainActor
final class QRHandoffPopoverController: NSViewController {

    private let response: ContinueQrResponse
    private let client: SoyehtAPIClient

    private let qrImageView = NSImageView()
    private let statusHeader = NSTextField(labelWithString: "Escaneie com a câmera do iPhone")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let connectedCheckmark = NSImageView()
    private let connectedLabel = NSTextField(labelWithString: "Conectado no iPhone")

    private var countdownTimer: Timer?
    private var pollTimer: Timer?
    private var expiresAt: Date?
    private var isClosing = false

    var onRequestClose: (() -> Void)?

    init(response: ContinueQrResponse, client: SoyehtAPIClient) {
        self.response = response
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root
        buildLayout(in: root)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 300, height: 380)

        statusHeader.font = Typography.sansNSFont(size: 13, weight: .semibold)
        statusHeader.alignment = .center

        countdownLabel.font = Typography.sansNSFont(size: 11)
        countdownLabel.textColor = .secondaryLabelColor
        countdownLabel.alignment = .center

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.cornerRadius = 8
        qrImageView.layer?.backgroundColor = NSColor.white.cgColor
        qrImageView.layer?.borderWidth = 1
        qrImageView.layer?.borderColor = NSColor.separatorColor.cgColor

        connectedCheckmark.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Conectado"
        )
        connectedCheckmark.contentTintColor = .systemGreen
        connectedCheckmark.symbolConfiguration = .init(pointSize: 64, weight: .medium)
        connectedCheckmark.isHidden = true

        connectedLabel.font = Typography.sansNSFont(size: 14, weight: .semibold)
        connectedLabel.alignment = .center
        connectedLabel.isHidden = true
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        expiresAt = Self.parseExpiresAt(response.expiresAt)
        updateCountdownLabel()
        loadQRImage()
        startTimers()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopTimers()
    }

    // MARK: - Layout

    private func buildLayout(in root: NSView) {
        [statusHeader, qrImageView, countdownLabel, connectedCheckmark, connectedLabel]
            .forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview($0)
            }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 300),
            root.heightAnchor.constraint(equalToConstant: 380),

            statusHeader.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            statusHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            qrImageView.topAnchor.constraint(equalTo: statusHeader.bottomAnchor, constant: 12),
            qrImageView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 260),
            qrImageView.heightAnchor.constraint(equalToConstant: 260),

            countdownLabel.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 12),
            countdownLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            countdownLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            connectedCheckmark.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            connectedCheckmark.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -16),
            connectedCheckmark.widthAnchor.constraint(equalToConstant: 80),
            connectedCheckmark.heightAnchor.constraint(equalToConstant: 80),

            connectedLabel.topAnchor.constraint(equalTo: connectedCheckmark.bottomAnchor, constant: 12),
            connectedLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            connectedLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Networking

    private func loadQRImage() {
        guard let url = client.continueQrImageURL(imageId: response.imageId) else { return }
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data) else { return }
                await MainActor.run {
                    self?.qrImageView.image = image
                }
            } catch {
                await MainActor.run {
                    self?.statusHeader.stringValue = "Falha ao carregar QR"
                    self?.statusHeader.textColor = .systemRed
                }
            }
        }
    }

    // MARK: - Timers

    private func startTimers() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCountdownLabel() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStatus() }
        }
    }

    private func stopTimers() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func updateCountdownLabel() {
        guard let exp = expiresAt else {
            countdownLabel.stringValue = "Token gerado"
            return
        }
        let remaining = max(0, Int(exp.timeIntervalSinceNow))
        if remaining == 0 && !isClosing {
            countdownLabel.stringValue = "Expirado"
            closeSoon(after: 0.2)
            return
        }
        let minutes = remaining / 60
        let seconds = remaining % 60
        countdownLabel.stringValue = String(format: "Expira em %d:%02d", minutes, seconds)
    }

    private func pollStatus() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let active = try await self.client.continueQrIsActive(token: self.response.token)
                if !active {
                    await MainActor.run { self.transitionToConnected() }
                }
            } catch {
                // Transient network errors — keep polling; popover still counts down.
            }
        }
    }

    private func transitionToConnected() {
        guard !isClosing else { return }
        isClosing = true
        statusHeader.stringValue = ""
        qrImageView.isHidden = true
        countdownLabel.isHidden = true
        connectedCheckmark.isHidden = false
        connectedLabel.isHidden = false
        stopTimers()
        closeSoon(after: 0.8)
    }

    private func closeSoon(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.onRequestClose?()
        }
    }

    // MARK: - Helpers

    private static func parseExpiresAt(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw)
    }
}
