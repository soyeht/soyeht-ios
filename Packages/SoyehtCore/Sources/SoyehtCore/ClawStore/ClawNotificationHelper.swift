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

    public static func sendInstallComplete(clawName: String, success: Bool) {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        if success {
            content.title = String(
                localized: "notify.claw.install.success.title",
                defaultValue: "\(clawName) installed",
                bundle: .module,
                comment: "Local notification title after a successful claw install. %@ = claw name (proper noun, do not translate)."
            )
            content.body = String(
                localized: "notify.claw.install.success.body",
                defaultValue: "\(clawName) is ready to deploy",
                bundle: .module,
                comment: "Local notification body after a successful claw install. %@ = claw name."
            )
        } else {
            content.title = String(
                localized: "notify.claw.install.failure.title",
                defaultValue: "\(clawName) install failed",
                bundle: .module,
                comment: "Local notification title after a failed claw install. %@ = claw name."
            )
            content.body = String(
                localized: "notify.claw.install.failure.body",
                bundle: .module,
                comment: "Local notification body after a failed claw install."
            )
        }
        content.sound = .default

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
