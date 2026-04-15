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

class SoyehtTerminalWindowController: NSWindowController {

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
}

extension SoyehtTerminalWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Window close is handled by the OS tab mechanism
    }
}
