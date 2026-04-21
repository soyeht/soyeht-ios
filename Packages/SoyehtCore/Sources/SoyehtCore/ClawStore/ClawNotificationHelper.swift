import UserNotifications

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
            content.title = "\(clawName) installed"
            content.body = "\(clawName) is ready to deploy"
        } else {
            content.title = "\(clawName) install failed"
            content.body = "check the claw store for details"
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
            content.title = "\(clawName) deployed"
            content.body = "\(clawName) is now running"
        } else {
            content.title = "\(clawName) deploy failed"
            content.body = "check the instance for details"
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
