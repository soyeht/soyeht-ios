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
}
