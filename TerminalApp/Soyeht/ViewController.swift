import UIKit
import SwiftUI

// `UIViewController` carries `@MainActor` in its iOS 17+ SDK declaration,
// so subclasses inherit isolation in Swift 6 mode. The annotation is
// repeated here explicitly so that (1) any future migration to
// `@preconcurrency import UIKit` does not silently strip isolation, and
// (2) the call site is unambiguous to readers and to lints that audit
// for this exact attribute on view controllers.
@MainActor
class ViewController: UIViewController {
    private var hostingController: UIHostingController<SoyehtAppView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = SoyehtAppView()
        let hosting = UIHostingController(rootView: rootView)
        hosting.overrideUserInterfaceStyle = SoyehtTheme.userInterfaceStyle
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        SoyehtTheme.statusBarStyle
    }
}
