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
    static var textMuted: NSColor { nsColor(appPalette.readableSecondaryTextOnBackgroundHex) }
    static var textPrimary: NSColor { nsColor(appPalette.textPrimaryHex) }
    static var textSecondary: NSColor { nsColor(appPalette.textSecondaryHex) }
    static var readableTextOnBackground: NSColor { nsColor(appPalette.readableTextOnBackgroundHex) }
    static var readableSecondaryTextOnBackground: NSColor { nsColor(appPalette.readableSecondaryTextOnBackgroundHex) }

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
    /// Canvas behind/between panes: classic keeps the historical gutter
    /// color, neo uses the chrome background so pane cards float on it.
    static var paneGridCanvas: NSColor {
        MacSurface.style == .neomorphic ? surfaceBase : gutter
    }
    /// Active-tab bottom stroke + sidebar-toggle tint when overlay open.
    static var accentBlue: NSColor { nsColor(appPalette.linkHex) }
    /// Success/accent token used for dots, team workspace groups, and
    /// mac-presence badges.
    static var accentGreenEmerald: NSColor { nsColor(appPalette.successHex) }
    static var selection: NSColor { nsColor(appPalette.selectionHex) }
    static var selectionText: NSColor { nsColor(appPalette.selectionTextHex) }
    static var readableTextOnSelection: NSColor { nsColor(appPalette.readableTextOnSelectionHex) }
    static var hover: NSColor { nsColor(appPalette.hoverHex) }
    static var buttonTextOnAccent: NSColor { nsColor(appPalette.buttonTextOnAccentHex) }
    static var paneTransientStatusText: NSColor { accentGreenEmerald }
    static var paneFloatingControlFill: NSColor { surfaceBase.withAlphaComponent(0.94) }
    static var paneFloatingControlStroke: NSColor { borderIdle.withAlphaComponent(0.9) }
    static var paneFloatingControlText: NSColor { readableSecondaryTextOnBackground }
    /// Fill for the active workspace tab (matches Pencil `tab-main.fill`).
    static var tabActiveFill: NSColor { nsColor(appPalette.surfaceRaisedHex) }
    /// Gold badge for iPhone device indicator in sidebar rows (Fase 7).
    static var accentIPhoneGold: NSColor { nsColor(appPalette.warningStrongHex) }
    /// Generic muted label color used across sidebar rows.
    static var textMutedSidebar: NSColor { nsColor(appPalette.readableSecondaryTextOnBackgroundHex) }
    /// Alias for the floating sidebar overlay base color (same as surfaceBase
    /// so the sidebar reads as a panel lifted from the same surface).
    static var sidebarBg: NSColor { surfaceBase }

    // MARK: - Neumorphic style colors

    private static var neoColors: NeoStyleColors {
        TerminalColorTheme.active.neoStyleColors
    }

    /// Raw terminal screen background — always the terminal theme's own
    /// background, never the chrome override (a neo preset's chrome is milk
    /// while its terminal screen stays dark).
    static var terminalScreen: NSColor { nsColor(TerminalColorTheme.active.backgroundHex) }

    /// Raised neumorphic surface (pills, chips, cards lifted off the canvas).
    static var neoSurface: NSColor { nsColor(neoColors.raisedSurfaceHex) }
    /// Recessed well (drawer track, grouped backgrounds).
    static var neoWell: NSColor { nsColor(neoColors.wellHex) }
    /// Down-right soft shadow cast by a raised surface.
    static var neoShadowDark: NSColor { nsColor(neoColors.shadowDarkHex) }
    /// Softened dark shadow for DARK surfaces on the light canvas (terminal
    /// screens): the full-strength tint hugs a dark edge like a smudge, so
    /// it is blended halfway toward the canvas — the card's own contrast
    /// plus the white rim do the separating.
    static var neoShadowDarkSoft: NSColor {
        nsColor(HexColorMath.mix(neoColors.shadowDarkHex, appPalette.backgroundHex, t: 0.55))
    }
    /// Up-left soft highlight cast by a raised surface.
    static var neoShadowLight: NSColor { nsColor(neoColors.shadowLightHex) }
    /// Colored glow behind accent-filled controls (apply alpha at call site).
    static var neoAccentShadow: NSColor { nsColor(neoColors.accentShadowHex) }

    /// Convex surface gradient (generator style: `linear-gradient(145deg)`).
    /// Light source top-left, so a raised surface is lighter at the start
    /// and settles slightly darker at the bottom-right.
    static var neoConvexStart: NSColor { nsColor(HexColorMath.lighten(neoColors.raisedSurfaceHex, by: 0.35)) }
    static var neoConvexEnd: NSColor { nsColor(HexColorMath.darken(neoColors.raisedSurfaceHex, by: 0.08)) }
    /// Concave (pressed) variant — same pair, reversed.
    static var neoConcaveStart: NSColor { neoConvexEnd }
    static var neoConcaveEnd: NSColor { neoConvexStart }
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
