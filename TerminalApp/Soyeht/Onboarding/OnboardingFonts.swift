import SwiftUI

/// Scalable typography tokens for iOS onboarding views (T121 — FR-081 Dynamic Type).
///
/// All tokens use SwiftUI TextStyle so they scale through AX1-AX5.
/// Never add `.font(.system(size: X))` for user-readable text — use these instead.
/// Decorative illustration emoji/icons may keep fixed sizes and must be .accessibilityHidden(true).
enum OnboardingFonts {
    static let heading      = Font.title2.weight(.semibold)           // 22pt base
    static let headingLarge = Font.title.weight(.semibold)            // 28pt base
    static let headingXL    = Font.largeTitle.weight(.semibold)       // 34pt base
    static let body         = Font.body                               // 17pt base
    static let bodyBold     = Font.body.weight(.semibold)             // 17pt semibold
    static let callout      = Font.callout                            // 16pt base
    static let subheadline  = Font.subheadline                        // 15pt base
    static let footnote     = Font.footnote                           // 13pt base
    static let caption      = Font.caption                            // 12pt base
    static let caption2     = Font.caption2                           // 11pt base
    static let caption2Bold = Font.caption2.weight(.semibold)         // 11pt semibold
    static let monoCode     = Font.system(.title3, design: .monospaced) // security code
}
