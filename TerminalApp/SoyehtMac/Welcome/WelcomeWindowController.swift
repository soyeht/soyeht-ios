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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Soyeht"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.setFrameAutosaveName("SoyehtWelcomeWindow")

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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Broadcast so any in-flight install (or other long task hosted in
        // the SwiftUI tree) can tear down subprocess state instead of being
        // abandoned.
        NotificationCenter.default.post(name: WelcomeWindowNotifications.willClose, object: nil)
    }
}
