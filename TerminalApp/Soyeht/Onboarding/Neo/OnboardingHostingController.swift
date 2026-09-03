import SoyehtCore
import SwiftUI
import UIKit

/// Host for every Layer-A onboarding root.
///
/// The app's window is dark: `SceneDelegate` stamps
/// `SoyehtTheme.userInterfaceStyle` on it, and the terminal wants that. The
/// onboarding does not — it is drawn on the neo canvas, which is a light
/// surface, and a dark window behind a light page shows up as a black seam
/// during the push and as white-on-white in the status bar.
///
/// So the host pins the light style and the dark status-bar content for its
/// own subtree, and paints the canvas on its view: the window's colour never
/// shows through, whatever the rest of the app is wearing.
final class OnboardingHostingController<Content: View>: UIHostingController<Content> {

    override init(rootView: Content) {
        super.init(rootView: rootView)
        overrideUserInterfaceStyle = .light
        view.backgroundColor = UIColor(NeoPalette.cloud.canvas)
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override var childForStatusBarStyle: UIViewController? { nil }
}
