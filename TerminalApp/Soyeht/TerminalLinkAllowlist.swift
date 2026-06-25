import Foundation
import UIKit

protocol URLOpening: AnyObject {
    func open(_ url: URL, from sourceView: UIView)
}

enum TerminalLinkAllowlist {
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    static func externalLinkURL(from rawLink: String) -> URL? {
        let trimmed = rawLink.trimmingCharacters(in: trimCharacters)
        guard let url = URL(string: trimmed),
              isAllowedExternalLink(url)
        else {
            return nil
        }
        return url
    }

    static func isAllowedExternalLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.trimmingCharacters(in: trimCharacters).lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.trimmingCharacters(in: trimCharacters),
              !host.isEmpty
        else {
            return false
        }
        return true
    }
}

final class ConfirmingURLOpener: URLOpening {
    static let shared = ConfirmingURLOpener()

    private init() {}

    func open(_ url: URL, from sourceView: UIView) {
        guard let presenter = Self.presentationController(for: sourceView) else { return }
        let alert = UIAlertController(
            title: String(localized: "Open link?"),
            message: url.absoluteString,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Open"), style: .default) { _ in
            UIApplication.shared.open(url)
        })
        presenter.present(alert, animated: true)
    }

    private static func presentationController(for view: UIView) -> UIViewController? {
        var controller = view.window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
