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

    // MARK: - SXnc2 "Floating Overlay" palette (V2 design)
    //
    // Intentionally separate from the original brand (`accentGreen`,
    // `surfaceDeep` above) so iOS / SoyehtCore aren't dragged into the
    // Mac-only visual refresh. When/if iOS adopts the same look, these
    // can be promoted to `BrandColors`.

    /// Main window + sidebar base. The new "canvas" behind everything.
    static let surfaceBase = NSColor(brandHex: "#1A1C25")
    /// Individual pane fill (behind the terminal view).
    static let paneBody = NSColor(brandHex: "#1D1F28")
    /// New pane header fill (replaces `paneHeaderFill` in Fase 3).
    static let paneHeaderNew = NSColor(brandHex: "#252731")
    /// Pane grid gutter (the strip that shows between split panes).
    static let gutter = NSColor(brandHex: "#2E3040")
    /// Active-tab bottom stroke + sidebar-toggle tint when overlay open.
    static let accentBlue = NSColor(brandHex: "#5B9CF6")
    /// Emerald green used for dots, team workspace groups, mac-presence
    /// badges. Hex matches the old hardcoded `#10B981` in WorkspaceTabView.
    static let accentGreenEmerald = NSColor(brandHex: "#10B981")
    /// Fill for the active workspace tab (matches Pencil `tab-main.fill`).
    static let tabActiveFill = NSColor(brandHex: "#2D3045")
    /// Gold badge for iPhone device indicator in sidebar rows (Fase 7).
    static let accentIPhoneGold = NSColor(brandHex: "#D4AF37")
    /// Generic muted label color used across sidebar rows.
    static let textMutedSidebar = NSColor(brandHex: "#555B6E")
    /// Alias for the floating sidebar overlay base color (same as surfaceBase
    /// so the sidebar reads as a panel lifted from the same surface).
    static var sidebarBg: NSColor { surfaceBase }
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
