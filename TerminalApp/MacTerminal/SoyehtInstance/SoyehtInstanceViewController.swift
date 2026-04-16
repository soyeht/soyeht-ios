//
//  SoyehtInstanceViewController.swift
//  MacTerminal
//

import Cocoa
import SwiftTerm
import SoyehtCore

class SoyehtInstanceViewController: NSViewController {

    private let instance: SoyehtInstance
    private let wsURL: String
    private let sessionName: String

    private var terminalView: MacOSWebSocketTerminalView!
    private var mirrorBanner: NSView?

    init(instance: SoyehtInstance, wsURL: String, sessionName: String) {
        self.instance = instance
        self.wsURL = wsURL
        self.sessionName = sessionName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        terminalView = MacOSWebSocketTerminalView(frame: view.bounds)
        terminalView.autoresizingMask = [.width, .height]

        applyAppearance()

        terminalView.onCommanderChanged = { [weak self] in
            self?.showMirrorBanner()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: .preferencesDidChange, object: nil)
        // Re-focus the terminal whenever this tab's window becomes key.
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)

        view.addSubview(terminalView)
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let w = note.object as? NSWindow, w === view.window else { return }
        view.window?.makeFirstResponder(terminalView)
    }

    @objc private func preferencesChanged() {
        applyAppearance()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = instance.name
        terminalView.configure(wsUrl: wsURL)
        // Ensure the terminal has keyboard focus when this tab first appears.
        // windowBecameKey may fire before viewDidAppear when the tab opens.
        view.window?.makeFirstResponder(terminalView)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
    }

    // MARK: - Appearance

    private func applyAppearance() {
        let theme = ColorTheme.active

        let fg = hexToNSColor(theme.foregroundHex)
        let bg = hexToNSColor(theme.backgroundHex)
        let cursor = hexToNSColor(theme.defaultCursorHex)

        terminalView.nativeForegroundColor = fg
        terminalView.nativeBackgroundColor = bg
        terminalView.caretColor = cursor
        terminalView.layer?.backgroundColor = bg.cgColor

        terminalView.installColors(theme.palette)

        terminalView.applyJetBrainsMono(size: TerminalPreferences.shared.fontSize)
    }

    private func hexToNSColor(_ hex: String) -> NSColor {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        return NSColor(
            calibratedRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    // MARK: - Mirror Mode

    private func showMirrorBanner() {
        guard mirrorBanner == nil else { return }

        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Mirror Mode — another device is commander")
        label.textColor = .white
        label.font = Typography.sansNSFont(size: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)

        let takeCommandButton = NSButton(title: "Take Command", target: self, action: #selector(takeCommand))
        takeCommandButton.bezelStyle = .rounded
        takeCommandButton.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(takeCommandButton)

        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: 36),

            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),

            takeCommandButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            takeCommandButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
        ])

        mirrorBanner = banner
    }

    private func hideMirrorBanner() {
        mirrorBanner?.removeFromSuperview()
        mirrorBanner = nil
    }

    @objc private func takeCommand() {
        hideMirrorBanner()
        terminalView.takeCommand()
    }

    // MARK: - Continue on iPhone

    private weak var continueOnIPhonePopover: NSPopover?

    /// Called by the window controller's toolbar item. Hits the backend to
    /// mint a short-lived QR token tied to `(container, sessionName)` and
    /// shows a popover with the server-rendered PNG.
    func presentContinueOnIPhone(anchor: NSView?) {
        // Idempotent: ignore taps while a popover is already visible.
        if continueOnIPhonePopover?.isShown == true { return }

        let anchorView: NSView = anchor ?? view

        Task { @MainActor in
            do {
                let resp = try await SoyehtAPIClient.shared.generateContinueQR(
                    container: instance.container,
                    workspaceId: sessionName
                )
                let vc = ContinueQRPopoverViewController(
                    response: resp,
                    client: SoyehtAPIClient.shared
                )
                let popover = NSPopover()
                popover.contentViewController = vc
                popover.behavior = .transient
                popover.animates = true
                vc.onRequestClose = { [weak popover] in popover?.performClose(nil) }

                continueOnIPhonePopover = popover
                popover.show(
                    relativeTo: anchorView.bounds,
                    of: anchorView,
                    preferredEdge: .minY
                )
            } catch {
                let alert = NSAlert()
                alert.messageText = "Não foi possível gerar o QR"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}

// MARK: - ContinueQRPopoverViewController

/// Popover content: a server-rendered QR image, countdown, and a polling
/// loop that detects when the iPhone has successfully redeemed the token.
/// When redemption is detected, the popover flips to a "Conectado" state
/// and closes itself after 800 ms.
private final class ContinueQRPopoverViewController: NSViewController {

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
            self?.updateCountdownLabel()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
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
