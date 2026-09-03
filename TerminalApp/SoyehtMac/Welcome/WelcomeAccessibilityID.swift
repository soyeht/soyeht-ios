import Foundation

/// Stable identifiers for the Welcome window, so QA can drive setup without
/// matching on visible text that translation changes under it.
enum WelcomeAccessibilityID {
    static let window = "soyeht.welcome.window"
    static let dots = "soyeht.welcome.dots"

    static let m1SetUp = "soyeht.welcome.m1.setUp"

    static let m2Progress = "soyeht.welcome.m2.progress"
    static let m2Phase = "soyeht.welcome.m2.phase"
    static let m2ApprovalCard = "soyeht.welcome.m2.approvalCard"
    static let m2OpenSettings = "soyeht.welcome.m2.openSettings"
    static let m2Recheck = "soyeht.welcome.m2.recheck"
    static let m2Retry = "soyeht.welcome.m2.retry"

    static let m3NameField = "soyeht.welcome.m3.nameField"
    static let m3Continue = "soyeht.welcome.m3.continue"
}
