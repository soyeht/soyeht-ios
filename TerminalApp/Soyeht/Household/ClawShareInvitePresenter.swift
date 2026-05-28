import UIKit
import SwiftUI
import Combine
import SoyehtCore

/// UIKit-level presenter that observes `ClawShareInviteCenter.shared`
/// and shows / hides the SwiftUI invite sheet over the current top
/// view controller as the router state changes.
///
/// Cross-cutting concern: the claw-share invite flow can happen from
/// ANY screen (carousel, install picker, main terminal). We bind a
/// single observer at app launch instead of adding `.sheet`
/// modifiers to every entry view; the sheet is always available the
/// moment the deep link consumes the URL.
@MainActor
final class ClawShareInviteSheetCoordinator {
    private weak var window: UIWindow?
    private var currentSheet: UIHostingController<ClawShareInviteSheet>?
    private var cancellables = Set<AnyCancellable>()

    init(window: UIWindow) {
        self.window = window
        // Bind to the published state. `.removeDuplicates(by:)` keeps
        // re-renders cheap; only structural changes (idle vs non-idle)
        // are worth re-evaluating the present/dismiss decision.
        ClawShareInviteCenter.shared.$state
            .map(Self.isIdle)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isIdle in
                self?.syncPresentation(isIdle: isIdle)
            }
            .store(in: &cancellables)
    }

    private static func isIdle(_ state: ClawShareRouterState) -> Bool {
        if case .idle = state { return true }
        return false
    }

    private func syncPresentation(isIdle: Bool) {
        if isIdle {
            dismissIfNeeded()
        } else {
            presentIfNeeded()
        }
    }

    private func presentIfNeeded() {
        guard currentSheet == nil else { return }
        guard let topVC = Self.topViewController(from: window?.rootViewController) else { return }
        let sheet = UIHostingController(
            rootView: ClawShareInviteSheet(center: ClawShareInviteCenter.shared)
        )
        sheet.modalPresentationStyle = .pageSheet
        sheet.isModalInPresentation = true
        sheet.view.accessibilityIdentifier = "ClawShareInviteSheet.host"
        currentSheet = sheet
        topVC.present(sheet, animated: true)
    }

    private func dismissIfNeeded() {
        guard let sheet = currentSheet else { return }
        sheet.dismiss(animated: true) { [weak self] in
            self?.currentSheet = nil
        }
    }

    private static func topViewController(from root: UIViewController?) -> UIViewController? {
        var current = root
        while let presented = current?.presentedViewController {
            current = presented
        }
        if let nav = current as? UINavigationController {
            return topViewController(from: nav.topViewController) ?? nav
        }
        if let tab = current as? UITabBarController {
            return topViewController(from: tab.selectedViewController) ?? tab
        }
        return current
    }
}
