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
    /// Pane header background (mj4II design `p*header.fill`). Slightly lighter
    /// than `surfaceDeep` so the 32pt header strip stays visible against the
    /// pane body.
    static let paneHeaderFill = NSColor(brandHex: "#101010")
    /// Idle pane border + header bottom stroke (design uses #1A1A1A).
    static let borderIdle = NSColor(brandHex: "#1A1A1A")
    // Lifted from #6B7280 to #9CA3AF so small muted text (pane header agent
    // subtitle, branch row, placeholder) clears WCAG AA 4.5:1 on #0A0A0A.
    static let textMuted   = NSColor(brandHex: "#9CA3AF")
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
