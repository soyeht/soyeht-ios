import AppKit
import SoyehtCore

/// macOS color tokens. SwiftUI brand `Color`s are shared via
/// `SoyehtCore.BrandColors`; this file provides AppKit `NSColor` equivalents
/// with identical hex values so iOS and macOS stay visually aligned.
///
/// Typography for macOS comes from `SoyehtCore.Typography` (`Typography.monoNSFont(...)`,
/// `Typography.sansNSFont(...)`) — there are no macOS-specific font tokens.
enum MacTheme {

    // MARK: - Brand (mirrors SoyehtCore.BrandColors)

    static let accentGreen = NSColor(brandHex: "#00D9A3")
    static let accentAmber = NSColor(brandHex: "#F59E0B")
    static let accentRed   = NSColor(brandHex: "#EF4444")
    static let surfaceDeep = NSColor(brandHex: "#0A0A0A")
    static let textMuted   = NSColor(brandHex: "#6B7280")
}

private extension NSColor {
    /// Brand hex → calibrated NSColor. Uses `SoyehtCore.ColorTheme.rgb8(from:)` for parsing
    /// so iOS and macOS use the exact same hex parser.
    convenience init(brandHex hex: String) {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        self.init(
            calibratedRed: CGFloat(r) / 255,
            green:         CGFloat(g) / 255,
            blue:          CGFloat(b) / 255,
            alpha:         1
        )
    }
}
