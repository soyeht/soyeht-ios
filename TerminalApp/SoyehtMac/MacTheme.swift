import AppKit
import SoyehtCore

/// macOS color tokens. SwiftUI brand `Color`s are shared via
/// `SoyehtCore.BrandColors`; this file provides AppKit `NSColor` equivalents
/// from the same active terminal-theme palette so iOS and macOS stay visually
/// aligned.
///
/// Typography for macOS comes from `MacTypography`, which wraps
/// `SoyehtCore.Typography` with semantic app-level font tokens.
enum MacTheme {
    private static var appPalette: SoyehtAppPalette {
        TerminalColorTheme.active.appPalette
    }

    private static func nsColor(_ hex: String) -> NSColor {
        NSColor(brandHex: hex)
    }

    // MARK: - Brand (mirrors SoyehtCore.BrandColors)

    static var accentGreen: NSColor { nsColor(appPalette.accentHex) }
    static var interactionAccent: NSColor { nsColor(appPalette.accentHex) }
    static var accentAmber: NSColor { nsColor(appPalette.warningHex) }
    static var accentRed: NSColor { nsColor(appPalette.dangerHex) }
    static var surfaceDeep: NSColor { nsColor(appPalette.backgroundHex) }
    /// Pane header background (mj4II design `p*header.fill`), derived from
    /// the active terminal theme's surface token.
    static var paneHeaderFill: NSColor { nsColor(appPalette.surfaceHex) }
    /// Idle pane border + header bottom stroke.
    static var borderIdle: NSColor { nsColor(appPalette.borderHex) }
    static var textMuted: NSColor { nsColor(appPalette.textMutedHex) }
    static var textPrimary: NSColor { nsColor(appPalette.textPrimaryHex) }
    static var textSecondary: NSColor { nsColor(appPalette.textSecondaryHex) }

    // MARK: - SXnc2 "Floating Overlay" palette (V2 design)
    //
    // Intentionally separate from the original brand (`accentGreen`,
    // `surfaceDeep` above) so iOS / SoyehtCore aren't dragged into the
    // Mac-only visual refresh. When/if iOS adopts the same look, these
    // can be promoted to `BrandColors`.

    /// Main window + sidebar base. The new "canvas" behind everything.
    static var surfaceBase: NSColor { nsColor(appPalette.backgroundHex) }
    /// Individual pane fill (behind the terminal view).
    static var paneBody: NSColor { nsColor(appPalette.cardHex) }
    /// New pane header fill (replaces `paneHeaderFill` in Fase 3).
    static var paneHeaderNew: NSColor { nsColor(appPalette.surfaceHex) }
    /// Pane grid gutter (the strip that shows between split panes).
    static var gutter: NSColor { nsColor(appPalette.borderHex) }
    /// Active-tab bottom stroke + sidebar-toggle tint when overlay open.
    static var accentBlue: NSColor { nsColor(appPalette.linkHex) }
    /// Success/accent token used for dots, team workspace groups, and
    /// mac-presence badges.
    static var accentGreenEmerald: NSColor { nsColor(appPalette.successHex) }
    static var selection: NSColor { nsColor(appPalette.selectionHex) }
    static var hover: NSColor { nsColor(appPalette.hoverHex) }
    static var buttonTextOnAccent: NSColor { nsColor(appPalette.buttonTextOnAccentHex) }
    /// Fill for the active workspace tab (matches Pencil `tab-main.fill`).
    static var tabActiveFill: NSColor { nsColor(appPalette.surfaceRaisedHex) }
    /// Gold badge for iPhone device indicator in sidebar rows (Fase 7).
    static var accentIPhoneGold: NSColor { nsColor(appPalette.warningStrongHex) }
    /// Generic muted label color used across sidebar rows.
    static var textMutedSidebar: NSColor { nsColor(appPalette.textMutedHex) }
    /// Alias for the floating sidebar overlay base color (same as surfaceBase
    /// so the sidebar reads as a panel lifted from the same surface).
    static var sidebarBg: NSColor { surfaceBase }
}

private extension NSColor {
    /// Brand hex → sRGB NSColor. Uses `SoyehtCore.ColorTheme.rgb8(from:)`
    /// for parsing so iOS and macOS use the exact same hex parser and the
    /// rendered desktop output matches the design hex values.
    convenience init(brandHex hex: String) {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        self.init(
            srgbRed:       CGFloat(r) / 255,
            green:         CGFloat(g) / 255,
            blue:          CGFloat(b) / 255,
            alpha:         1
        )
    }
}
