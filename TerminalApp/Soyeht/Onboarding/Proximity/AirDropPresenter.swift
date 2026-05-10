import Foundation
import UIKit
import SoyehtCore

/// Presents an AirDrop-only share sheet for the bundled `Soyeht.dmg` (FR-023 research R1).
///
/// All activity types except AirDrop are excluded so the system sheet shows only
/// the AirDrop row. Completion returns `.success` only if the user actually shared;
/// any other result routes to `onFallback` which surfaces `QRFallbackView`.
@MainActor
final class AirDropPresenter {
    enum Result {
        case success
        case fallback
    }

    private weak var presentingViewController: UIViewController?

    init(presentingViewController: UIViewController) {
        self.presentingViewController = presentingViewController
    }

    func present() async -> Result {
        guard let dmgURL = Self.bundledDmgURL() else {
            return .fallback
        }

        return await withCheckedContinuation { continuation in
            let provider = NSItemProvider(contentsOf: dmgURL)
            let vc = UIActivityViewController(
                activityItems: [provider as Any],
                applicationActivities: nil
            )

            // Exclude everything except AirDrop (UIActivityType.airDrop).
            vc.excludedActivityTypes = UIActivity.ActivityType.allExcludingAirDrop

            vc.completionWithItemsHandler = { _, completed, _, _ in
                continuation.resume(returning: completed ? .success : .fallback)
            }

            presentingViewController?.present(vc, animated: true)
        }
    }

    private static func bundledDmgURL() -> URL? {
        Bundle.main.url(forResource: "Soyeht", withExtension: "dmg")
    }
}

// MARK: - UIActivity.ActivityType extension

extension UIActivity.ActivityType {
    /// All known activity types except AirDrop, for use as `excludedActivityTypes`.
    static let allExcludingAirDrop: [UIActivity.ActivityType] = [
        .addToReadingList,
        .assignToContact,
        .copyToPasteboard,
        .mail,
        .message,
        .openInIBooks,
        .postToFacebook,
        .postToFlickr,
        .postToTencentWeibo,
        .postToTwitter,
        .postToVimeo,
        .postToWeibo,
        .print,
        .saveToCameraRoll,
        .markupAsPDF,
        .sharePlay,
        .collaborationCopyLink,
        .collaborationInviteWithLink,
    ]
}
