import Foundation
import UserNotifications

/// Notifications the macOS app observes to keep caches in sync with the
/// Claw Store. Fired by the shared ViewModels after a successful install /
/// uninstall so consumers (e.g. the pane picker's installed-claws cache)
/// can refresh without each one polling the server.
public enum ClawStoreNotifications {
    /// Posted after `ClawStoreViewModel` or `ClawDetailViewModel` completes
    /// an install/uninstall and sees a terminal install state for the
    /// affected claw. UserInfo is empty — consumers should re-fetch via
    /// `SoyehtAPIClient.getClaws` to read the fresh projection.
    public static let installedSetChanged = Notification.Name("soyeht.claws.installedSetChanged")

    /// Posted by `SessionStore.setActiveServer` when the user switches the
    /// active paired server. Consumers that cache per-server data (e.g.
    /// `InstalledClawsProvider`) must discard their cache and re-fetch from
    /// the new server.
    public static let activeServerChanged = Notification.Name("soyeht.sessions.activeServerChanged")
}

// MARK: - Claw Install Notification Helper
//
// `UNUserNotificationCenter` is available on both iOS 10+ and macOS 10.14+,
// so the helper lives in SoyehtCore as-is. The iOS target grants the initial
// authorization prompt when the store first opens; macOS does the same on
// first use.

public enum ClawNotificationHelper {

    public static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    /// Composes the notification content for an install-complete event without scheduling.
    /// Exposed separately so tests can assert the localized title/body without invoking
    /// UNUserNotificationCenter (which requires app entitlements and async authorization).
    ///
    /// Implementation note: `LocalizedStringResource.locale` is a *hint* that Foundation may
    /// ignore in favor of `.current`. To actually force a specific locale, we resolve the
    /// matching `.lproj` sub-bundle inside `Bundle.module` and look the key up there.
    public static func makeInstallCompleteContent(
        clawName: String,
        success: Bool,
        locale: Locale = .current
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let bundle = localeBundle(for: locale)
        if success {
            let titleFmt = bundle.localizedString(forKey: "notify.claw.install.success.title", value: "%@ installed", table: nil)
            content.title = String(format: titleFmt, clawName)
            let bodyFmt = bundle.localizedString(forKey: "notify.claw.install.success.body", value: "%@ is ready to deploy", table: nil)
            content.body = String(format: bodyFmt, clawName)
        } else {
            let titleFmt = bundle.localizedString(forKey: "notify.claw.install.failure.title", value: "%@ install failed", table: nil)
            content.title = String(format: titleFmt, clawName)
            // Fallback mirrors the en catalog value so that, if the key is ever removed
            // from the catalog, users still see a coherent sentence instead of the
            // placeholder-style "install failure body" used during development.
            let bodyFmt = bundle.localizedString(forKey: "notify.claw.install.failure.body", value: "check the claw store for details", table: nil)
            content.body = bodyFmt
        }
        content.sound = .default
        return content
    }

    /// Resolves the matching `.lproj` sub-bundle for an explicit locale. Falls back to the
    /// base language (e.g. `ar_SA` → `ar`) and finally to `Bundle.module`.
    private static func localeBundle(for locale: Locale) -> Bundle {
        let module = Bundle.module
        let candidates: [String] = [
            locale.identifier,
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
            locale.language.languageCode?.identifier,
        ].compactMap { $0 }
        for id in candidates {
            if let url = module.url(forResource: id, withExtension: "lproj"),
               let b = Bundle(url: url) {
                return b
            }
        }
        return module
    }

    public static func sendInstallComplete(clawName: String, success: Bool) {
        let center = UNUserNotificationCenter.current()
        let content = makeInstallCompleteContent(clawName: clawName, success: success)
        let request = UNNotificationRequest(
            identifier: "claw-install-\(clawName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    public static func sendDeployComplete(clawName: String, success: Bool) {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        if success {
            content.title = String(
                localized: "notify.claw.deploy.success.title",
                defaultValue: "\(clawName) deployed",
                bundle: .module,
                comment: "Local notification title after a successful claw deploy. %@ = claw name."
            )
            content.body = String(
                localized: "notify.claw.deploy.success.body",
                defaultValue: "\(clawName) is now running",
                bundle: .module,
                comment: "Local notification body after a successful claw deploy. %@ = claw name."
            )
        } else {
            content.title = String(
                localized: "notify.claw.deploy.failure.title",
                defaultValue: "\(clawName) deploy failed",
                bundle: .module,
                comment: "Local notification title after a failed claw deploy. %@ = claw name."
            )
            content.body = String(
                localized: "notify.claw.deploy.failure.body",
                bundle: .module,
                comment: "Local notification body after a failed claw deploy."
            )
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claw-deploy-\(clawName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
