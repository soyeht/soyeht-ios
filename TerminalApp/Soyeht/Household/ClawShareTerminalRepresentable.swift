import SwiftUI
import SoyehtCore

/// Bridges the UIKit `ClawShareTerminalViewController` into SwiftUI so the
/// invite sheet can present the real interactive terminal via
/// `.fullScreenCover`. The VC is wrapped in a navigation controller so the
/// close button (and the recoverable end-of-session state) render with a bar.
///
/// The client is created + session-started by `ClawShareOpenController`; this
/// representable owns only presentation. `onClosed` fires when the user closes
/// or dismisses the recoverable state, so the host can clear the launch and
/// let the gate be re-entered from the share.
struct ClawShareTerminalRepresentable: UIViewControllerRepresentable {
    let launch: ClawShareTerminalLaunch
    let onClosed: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let terminal = ClawShareTerminalViewController(
            client: launch.client,
            clawDisplayName: launch.displayName
        )
        terminal.onClosed = onClosed
        let nav = UINavigationController(rootViewController: terminal)
        nav.modalPresentationStyle = .fullScreen
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // The terminal VC drives its own state; nothing to push from SwiftUI.
    }
}
