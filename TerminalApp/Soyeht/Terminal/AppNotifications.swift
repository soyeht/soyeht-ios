import Foundation

extension Notification.Name {
    static let soyehtTerminalResumeLive = Notification.Name("soyehtTerminalResumeLive")
    static let soyehtConnectionLost = Notification.Name("soyehtConnectionLost")
    static let soyehtInsertIntoTerminal = Notification.Name("soyehtInsertIntoTerminal")
    static let soyehtFontSizeChanged = Notification.Name("soyehtFontSizeChanged")
    static let soyehtCursorStyleChanged = Notification.Name("soyehtCursorStyleChanged")
    static let soyehtCursorColorChanged = Notification.Name("soyehtCursorColorChanged")
    static let soyehtHapticSettingsChanged = Notification.Name("soyehtHapticSettingsChanged")
    static let soyehtColorThemeChanged = Notification.Name("soyehtColorThemeChanged")
    static let soyehtVoiceInputSettingsChanged = Notification.Name("soyehtVoiceInputSettingsChanged")
    static let soyehtShortcutBarChanged = Notification.Name("soyehtShortcutBarChanged")
    static let soyehtDeepLink = Notification.Name("soyehtDeepLink")
    /// Posted from in-app views (e.g. QR scanner, home banner) when the user
    /// wants to step back into the platform-pick onboarding flow.
    /// Observed by SceneDelegate, which swaps the window root to InstallPicker.
    static let soyehtRequestInstallPicker = Notification.Name("soyehtRequestInstallPicker")
}

enum SoyehtNotificationKey {
    static let container = "container"
    static let session = "session"
    static let text = "text"
}
