import AppKit
import SwiftUI

enum SoyehtUninstallPresentationContext: Equatable {
    case inApp
    case companion
}

final class UninstallWindowController: NSWindowController, NSWindowDelegate {
    init(context: SoyehtUninstallPresentationContext) {
        let size = NSSize(width: 960, height: 760)
        let minSize = NSSize(width: 860, height: 640)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "uninstall.window.title",
            defaultValue: "Uninstall Soyeht",
            comment: "Window title for the complete graphical Soyeht uninstaller."
        )
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = minSize

        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: UninstallTheyOSView(
            onCompleted: { [weak window] in window?.close() },
            compact: false,
            context: context
        ))
        window.setContentSize(size)
        Self.placeOnPrimaryScreen(window: window, size: size)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for UninstallWindowController")
    }

    private static func placeOnPrimaryScreen(window: NSWindow, size: NSSize) {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        window.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }
}

final class UninstallCompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: UninstallWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = UninstallWindowController(context: .companion)
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
