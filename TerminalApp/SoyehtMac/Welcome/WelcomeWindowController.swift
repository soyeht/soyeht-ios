import AppKit
import SwiftUI

/// Notifications the Welcome window broadcasts so SwiftUI children can
/// react to AppKit lifecycle events. Used today by `LocalInstallView` to
/// terminate a running install when the user closes the window mid-run —
/// otherwise the `brew`/`soyeht` subprocess would be orphaned.
enum WelcomeWindowNotifications {
    static let willClose = Notification.Name("soyeht.welcome.willClose")
}

/// Dedicated window for the first-launch onboarding flow. Replaces the
/// legacy "open main window + sheet a login VC" approach because that
/// left an empty workspace visible behind the sheet — the user saw a dead
/// window before any pairing happened.
///
/// Lifecycle:
///   - `AppDelegate` constructs us when `SessionStore.pairedServers` is empty.
///   - We host `WelcomeRootView` via `NSHostingController`.
///   - On successful pair, `onComplete` fires and `AppDelegate` opens the
///     main window + closes us. Reused if the user logs out of the last
///     server (US-05 / product decision Opção A).
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {

    /// Invoked after a successful pair or install+autopair. Responsibility
    /// of the owner (AppDelegate) to close this window and launch the main
    /// workspace.
    var onComplete: (() -> Void)?

    init() {
        let size = NSSize(width: 640, height: 540)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Soyeht"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Explicitly anchor the window on the user's primary display
        // (the one carrying the menu bar). We deliberately don't use
        // `setFrameAutosaveName` here: multi-monitor setups that
        // disconnect/reconnect — or a previous run that left the window
        // straddling two screens — would otherwise restore that broken
        // position on next launch. This is the onboarding window, only
        // shown briefly during install/pair, so losing per-user manual
        // positioning is an acceptable trade.
        Self.placeOnPrimaryScreen(window: window, size: size)

        super.init(window: window)
        window.delegate = self

        // The hosting controller is created here (after `super.init` so
        // `self` is available for the completion closure) and the root view
        // pipes its success callback through our `onComplete` hook.
        let root = WelcomeRootView(onPaired: { [weak self] in
            self?.onComplete?()
        })
        window.contentViewController = NSHostingController(rootView: root)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for WelcomeWindowController")
    }

    /// Anchor the window on the user's primary display before it ever
    /// becomes visible. `NSScreen.screens.first` is the menu-bar screen
    /// on a multi-monitor setup; we fall back to `.main` (key-window
    /// screen) and, as a last resort, the AppKit-provided `.center()`.
    private static func placeOnPrimaryScreen(window: NSWindow, size: NSSize) {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Broadcast so any in-flight install (or other long task hosted in
        // the SwiftUI tree) can tear down subprocess state instead of being
        // abandoned.
        NotificationCenter.default.post(name: WelcomeWindowNotifications.willClose, object: nil)
    }
}
