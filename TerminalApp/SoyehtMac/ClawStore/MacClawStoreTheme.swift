import SwiftUI
import SoyehtCore

/// SwiftUI color tokens consumed by the macOS Claw Store views. Values
/// are duplicated from the iOS SoyehtTheme hex codes so the two targets
/// render the same surface shades without either depending on the
/// other's theme file.
enum MacClawStoreTheme {
    static let bgPrimary     = Color(hex: "#0A0A0A")
    static let bgCard        = Color(hex: "#141414")
    static let bgCardBorder  = Color(hex: "#222222")
    static let bgRowHover    = Color.white.opacity(0.04)

    static let accentGreen   = BrandColors.accentGreen
    static let accentAmber   = BrandColors.accentAmber
    static let statusGreen   = Color(hex: "#10B981")
    static let statusGreenBg = Color(hex: "#10B981").opacity(0.15)

    static let textPrimary   = Color.white
    static let textSecondary = Color(hex: "#888888")
    static let textMuted     = BrandColors.textMuted
    static let textWarning   = Color(hex: "#FFAA00")
    static let textComment   = Color(hex: "#666666")
}
