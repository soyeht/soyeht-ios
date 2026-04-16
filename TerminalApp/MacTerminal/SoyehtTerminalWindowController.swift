//
//  SoyehtTerminalWindowController.swift
//  MacTerminal
//
//  Programmatic NSWindowController for Soyeht WebSocket terminal tabs.
//  Uses tabbingIdentifier = "SoyehtTerminal" to join the same tab group
//  as LocalShellWindowController.
//

import Cocoa
import SoyehtCore

final class SoyehtTerminalWindowController: NSWindowController, NSToolbarDelegate {

    private static let continueOnIPhoneIdentifier = NSToolbarItem.Identifier("ContinueOnIPhone")

    private weak var continueToolbarItem: NSToolbarItem?

    init(instance: SoyehtInstance, wsURL: String, sessionName: String) {
        let vc = SoyehtInstanceViewController(instance: instance, wsURL: wsURL, sessionName: sessionName)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = instance.name
        window.contentViewController = vc
        window.tabbingIdentifier = "SoyehtTerminal"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        // Programmatic windows don't fire `windowDidLoad`, so wire the toolbar
        // synchronously once the window + content VC are in place.
        setupToolbar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func newWindowForTab(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let myWindow = window else { return }
        let wc = appDelegate.makeLocalShellWC()
        guard let newWindow = wc.window else { return }
        myWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(sender)
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "SoyehtTerminalToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window?.toolbarStyle = .unified
        }
        toolbar.isVisible = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.continueOnIPhoneIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.continueOnIPhoneIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.continueOnIPhoneIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.image = NSImage(
            systemSymbolName: "iphone.and.arrow.forward",
            accessibilityDescription: "Continue on iPhone"
        )
        item.label = "Continue on iPhone"
        item.paletteLabel = "Continue on iPhone"
        item.toolTip = "Generate a QR code to continue this session on your iPhone"
        item.target = self
        item.action = #selector(continueOnIPhoneTapped(_:))
        item.isBordered = true
        continueToolbarItem = item
        return item
    }

    // MARK: - Actions

    @objc private func continueOnIPhoneTapped(_ sender: Any?) {
        guard let vc = window?.contentViewController as? SoyehtInstanceViewController else {
            return
        }
        let anchor: NSView? = continueToolbarItem?.view
            ?? (sender as? NSView)
        vc.presentContinueOnIPhone(anchor: anchor)
    }
}

extension SoyehtTerminalWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Window close is handled by the OS tab mechanism
    }
}
