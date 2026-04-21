import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SoyehtCore

/// Inline hand-off panel for the per-pane "Continue on iPhone" flow.
///
/// Shows a locally rendered QR image, the same deep link as copyable text, and
/// polls every 2s until the server reports the token has been redeemed — at
/// which point the panel flips to a "Conectado" checkmark and closes itself
/// shortly after.
@MainActor
final class QRHandoffPopoverController: NSViewController {
    private static let qrContext = CIContext()

    private let deepLink: String
    private let expiresAtRaw: String
    private let pendingPoller: @Sendable () async throws -> Bool

    private let cardView = NSView()
    private let qrImageView = NSImageView()
    private let statusHeader = NSTextField(labelWithString: String(localized: "qrHandoff.header.title", comment: "Header of the 'Continue on iPhone' QR hand-off popover."))
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: String(localized: "qrHandoff.header.subtitle", comment: "Subtitle explaining the two ways to redeem the QR link (camera scan OR paste into Soyeht iOS).")
    )
    private let countdownLabel = NSTextField(labelWithString: "")
    private let linkHeader = NSTextField(labelWithString: String(localized: "qrHandoff.link.header", comment: "Section header above the copyable deep link text — typically the literal 'LINK'."))
    private let deepLinkLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: String(localized: "qrHandoff.button.copy", comment: "Button that copies the deep link to the clipboard."), target: nil, action: nil)
    private let connectedCheckmark = NSImageView()
    private let connectedLabel = NSTextField(labelWithString: String(localized: "qrHandoff.connected.label", comment: "Label shown after the iPhone redeems the QR — pane is now open on iPhone."))

    private var countdownTimer: Timer?
    private var pollTimer: Timer?
    private var expiresAt: Date?
    private var isClosing = false
    private var copyResetTask: Task<Void, Never>?

    var onRequestClose: (() -> Void)?

    init(
        deepLink: String,
        expiresAt: String,
        pendingPoller: @escaping @Sendable () async throws -> Bool
    ) {
        self.deepLink = deepLink
        self.expiresAtRaw = expiresAt
        self.pendingPoller = pendingPoller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        self.view = root
        buildLayout(in: root)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 420, height: 520)

        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = NSColor(
            srgbRed: 0x10 / 255,
            green: 0x10 / 255,
            blue: 0x10 / 255,
            alpha: 1
        ).cgColor
        cardView.layer?.cornerRadius = 14
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.separatorColor.cgColor

        statusHeader.font = Typography.sansNSFont(size: 13, weight: .semibold)
        statusHeader.alignment = .center

        subtitleLabel.font = Typography.sansNSFont(size: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3

        countdownLabel.font = Typography.sansNSFont(size: 11)
        countdownLabel.textColor = .secondaryLabelColor
        countdownLabel.alignment = .center

        linkHeader.font = Typography.monoNSFont(size: 11, weight: .semibold)
        linkHeader.textColor = .secondaryLabelColor

        deepLinkLabel.stringValue = deepLink
        deepLinkLabel.font = Typography.monoNSFont(size: 11, weight: .regular)
        deepLinkLabel.textColor = .labelColor
        deepLinkLabel.maximumNumberOfLines = 3
        deepLinkLabel.lineBreakMode = .byCharWrapping
        deepLinkLabel.toolTip = deepLink

        copyButton.target = self
        copyButton.action = #selector(copyLinkTapped)
        copyButton.bezelStyle = .rounded
        updateCopyButtonTitle(String(localized: "qrHandoff.button.copy", comment: "Button that copies the deep link to the clipboard."))

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.cornerRadius = 8
        qrImageView.layer?.backgroundColor = NSColor.white.cgColor
        qrImageView.layer?.borderWidth = 1
        qrImageView.layer?.borderColor = NSColor.separatorColor.cgColor

        connectedCheckmark.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: String(localized: "qrHandoff.connected.a11y", comment: "VoiceOver description for the green checkmark shown when the iPhone has redeemed the QR.")
        )
        connectedCheckmark.contentTintColor = .systemGreen
        connectedCheckmark.symbolConfiguration = .init(pointSize: 64, weight: .medium)
        connectedCheckmark.imageScaling = .scaleNone
        connectedCheckmark.isHidden = true

        connectedLabel.font = Typography.sansNSFont(size: 14, weight: .semibold)
        connectedLabel.alignment = .center
        connectedLabel.isHidden = true
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        copyResetTask?.cancel()
        copyResetTask = nil
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        expiresAt = Self.parseExpiresAt(expiresAtRaw)
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
        cardView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cardView)

        [statusHeader, subtitleLabel, qrImageView, countdownLabel, linkHeader, deepLinkLabel, copyButton, connectedCheckmark, connectedLabel]
            .forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                cardView.addSubview($0)
            }

        let preferredWidth = cardView.widthAnchor.constraint(equalToConstant: 360)
        preferredWidth.priority = .defaultHigh
        let topInset = cardView.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 24)
        topInset.priority = .defaultLow
        let bottomInset = cardView.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        bottomInset.priority = .defaultLow

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            preferredWidth,
            topInset,
            bottomInset,

            statusHeader.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            statusHeader.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            statusHeader.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: statusHeader.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            subtitleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),

            qrImageView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            qrImageView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 220),
            qrImageView.heightAnchor.constraint(equalToConstant: 220),

            countdownLabel.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 12),
            countdownLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            countdownLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),

            linkHeader.topAnchor.constraint(equalTo: countdownLabel.bottomAnchor, constant: 16),
            linkHeader.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            linkHeader.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),

            deepLinkLabel.topAnchor.constraint(equalTo: linkHeader.bottomAnchor, constant: 8),
            deepLinkLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            deepLinkLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),

            copyButton.topAnchor.constraint(equalTo: deepLinkLabel.bottomAnchor, constant: 14),
            copyButton.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            copyButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),

            connectedCheckmark.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            connectedCheckmark.centerYAnchor.constraint(equalTo: cardView.centerYAnchor, constant: -16),
            connectedCheckmark.widthAnchor.constraint(equalToConstant: 80),
            connectedCheckmark.heightAnchor.constraint(equalToConstant: 80),

            connectedLabel.topAnchor.constraint(equalTo: connectedCheckmark.bottomAnchor, constant: 12),
            connectedLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            connectedLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
        ])
    }

    // MARK: - Networking

    private func loadQRImage() {
        if let image = Self.makeQRImage(from: deepLink) {
            qrImageView.image = image
        } else {
            statusHeader.stringValue = String(localized: "qrHandoff.qrFailed", comment: "Shown in place of the QR when rendering it failed.")
            statusHeader.textColor = .systemRed
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
            countdownLabel.stringValue = String(localized: "qrHandoff.countdown.tokenGenerated", comment: "Fallback label when we don't yet know the expiration time.")
            return
        }
        let remaining = max(0, Int(exp.timeIntervalSinceNow))
        if remaining == 0 && !isClosing {
            countdownLabel.stringValue = String(localized: "qrHandoff.countdown.expired", comment: "Shown when the QR token has expired. Panel will auto-close right after.")
            closeSoon(after: 0.2)
            return
        }
        let minutes = remaining / 60
        let seconds = remaining % 60
        countdownLabel.stringValue = String(
            localized: "qrHandoff.countdown.format",
            defaultValue: "Expires in \(minutes):\(String(format: "%02d", seconds))",
            comment: "Countdown to token expiration. %1$lld = minutes, %2$@ = zero-padded seconds string."
        )
    }

    private func pollStatus() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let active = try await self.pendingPoller()
                if !active {
                    await MainActor.run { self.transitionToConnected() }
                }
            } catch {
                // Transient network errors — keep polling; the panel still counts down.
            }
        }
    }

    private func transitionToConnected() {
        guard !isClosing else { return }
        isClosing = true
        statusHeader.stringValue = ""
        subtitleLabel.isHidden = true
        qrImageView.isHidden = true
        countdownLabel.isHidden = true
        linkHeader.isHidden = true
        deepLinkLabel.isHidden = true
        copyButton.isHidden = true
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

    @objc private func copyLinkTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deepLink, forType: .string)
        updateCopyButtonTitle(String(localized: "qrHandoff.button.copied", comment: "Temporary button state after copying — resets to the normal title a few seconds later."))
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.updateCopyButtonTitle(String(localized: "qrHandoff.button.copy", comment: "Button that copies the deep link to the clipboard."))
        }
    }

    private func updateCopyButtonTitle(_ title: String) {
        copyButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Typography.monoNSFont(size: 12, weight: .semibold),
            ]
        )
    }

    private static func makeQRImage(from deepLink: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(deepLink.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = qrContext.createCGImage(output, from: output.extent) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: output.extent.width, height: output.extent.height)
        )
    }
}
