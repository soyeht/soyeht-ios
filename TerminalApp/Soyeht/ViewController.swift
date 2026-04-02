import UIKit
import SwiftUI

class ViewController: UIViewController {
    private var hostingController: UIHostingController<SoyehtAppView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = SoyehtAppView()
        let hosting = UIHostingController(rootView: rootView)
        hosting.overrideUserInterfaceStyle = .dark
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
        .lightContent
    }
}
