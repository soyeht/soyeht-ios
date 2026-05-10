import SwiftUI

/// Scalable typography tokens for iOS onboarding views (T121 — FR-081 Dynamic Type).
///
/// All tokens use SwiftUI TextStyle so they scale through AX1-AX5.
/// Never add `.font(.system(size: X))` for user-readable text — use these instead.
/// Decorative illustration emoji/icons may keep fixed sizes and must be .accessibilityHidden(true).
public enum OnboardingFonts {
    public static let heading      = Font.title2.weight(.semibold)           // 22pt base
    public static let headingLarge = Font.title.weight(.semibold)            // 28pt base
    public static let headingXL    = Font.largeTitle.weight(.semibold)       // 34pt base
    public static let body         = Font.body                               // 17pt base
    public static let bodyBold     = Font.body.weight(.semibold)             // 17pt semibold
    public static let callout      = Font.callout                            // 16pt base
    public static let subheadline  = Font.subheadline                        // 15pt base
    public static let footnote     = Font.footnote                           // 13pt base
    public static let caption      = Font.caption                            // 12pt base
    public static let caption2     = Font.caption2                           // 11pt base
    public static let caption2Bold = Font.caption2.weight(.semibold)         // 11pt semibold
    public static let monoCode     = Font.system(.title3, design: .monospaced) // security code
}
