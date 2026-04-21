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
    private var activeServerObserver: NSObjectProtocol?

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

        // The view tree is pinned to `context` at init. When the active
        // server changes we can't rebuild the view hierarchy cleanly (the
        // SwiftUI state is owned by NSHostingController), so the simplest
        // correct answer is to close the window — the user reopens it and
        // picks up the new context. Prevents the store from silently
        // talking to the previous server.
        activeServerObserver = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.activeServerChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        }
    }

    deinit {
        if let observer = activeServerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ClawStoreWindowController")
    }
}
