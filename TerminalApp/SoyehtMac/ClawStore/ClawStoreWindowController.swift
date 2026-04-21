import AppKit
import SwiftUI
import SoyehtCore

/// Dedicated NSWindow for the macOS Claw Store. Coexists with the main
/// workspace window — users keep terminals open while browsing/installing
/// claws, which matches the App Store mental model called out in the
/// roadmap (US-06).
@MainActor
final class ClawStoreWindowController: NSWindowController {
    private let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Claw Store"
        window.titlebarAppearsTransparent = true
        window.center()
        window.setFrameAutosaveName("SoyehtClawStoreWindow")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MacClawStoreRootView(context: context))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ClawStoreWindowController")
    }
}
