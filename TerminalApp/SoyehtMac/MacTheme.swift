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

    /// Pane header pill (reference: pastel accent tint floating inside the
    /// light frame, e.g. `#D9E4FA` on the blue variant).
    static var neoHeaderPill: NSColor {
        nsColor(HexColorMath.mix(appPalette.accentHex, "#FFFFFF", t: 0.74))
    }

    /// How many agent identity colors a theme carries.
    ///
    /// Five, down from eight. Eight forced the chroma down to 10 to keep the
    /// set from glaring, and at that chroma eight hues are impossible to tell
    /// apart — the count was defeating its own purpose. Halving it doubles the
    /// spacing, so each color can carry C* 20-28 and still sit quietly.
    static let neoHeaderPastelCount = 5

    /// Per-pane header identity colors: the pill an agent's name sits on.
    ///
    /// Four FIXED hues — violet, rose, green, cyan — the same on every theme,
    /// in that order. An agent keeps its color when the theme changes, which
    /// is what lets the color mean the agent rather than the theme.
    ///
    /// Two earlier attempts anchored the set on each theme's accent, and both
    /// were wrong the same way: anchoring rotates the sequence, so the order
    /// came out different on every theme. It only looked right on Pale Mist
    /// and Misty Blue, whose accents happen to sit where these four fall — and
    /// re-anchoring to "fix" the other six is what broke those two.
    ///
    /// What follows the theme is the TONE, not the hue. Lightness and chroma
    /// are the theme's own register, so the same violet is a pale lilac on
    /// Sunlit Chartreuse (L* 76, C* 28) and a deep plum on Deep Forest (L* 14,
    /// C* 16). All four share that register, which is what makes them read as
    /// one set.
    ///
    /// The fifth is the theme's own selection color taken a shade deeper. It
    /// is the only slot whose hue comes from the theme, which is why it is the
    /// one a pane wears by default.
    ///
    /// The plate sinks 9 L* below the card. The previous set sank 5 at C* 10
    /// and had effectively vanished: the header became a band of text with no
    /// pill, which is what lost the agent's identity — not contrast, which was
    /// already 6:1 to 12:1 throughout. A surface too dark to sink a plate into
    /// steps up instead, the only direction left to it.
    static var neoHeaderPastels: [NSColor] {
        let palette = appPalette
        let surface = LabColorMath.lch(of: palette.surfaceHex)
        let sunk = surface.lightness - 9
        // A face too dark to sink into steps up — but to where color is
        // actually possible, not by a fixed amount. soyehtDark is pure black,
        // and a flat +8 landed at L* 8, where sRGB holds almost no chroma and
        // five slots collapse into one.
        let lightness = sunk >= 12 ? sunk : max(surface.lightness + 8, 18)

        let hues = [317.0, 7.0, 137.0, 187.0]
        // One chroma every hue in the set can actually reach, so the four read
        // as siblings instead of one washed-out member beside three vivid ones.
        let chroma = min(28, hues.map {
            LabColorMath.maxChroma(lightness: lightness, hue: $0)
        }.min() ?? 28)

        let selection = LabColorMath.lch(of: palette.selectionHex)
        return (hues.map { hue in
            Self.plateClear(of: palette.surfaceHex,
                            at: LabColorMath.LCh(lightness: lightness, chroma: chroma, hue: hue))
        } + [Self.readableSelectionPlate(selection,
                                         ink: palette.textPrimaryHex,
                                         fallback: lightness)])
            .map { nsColor(LabColorMath.hex($0)) }
    }

    /// A plate whose hue is the theme's own hue would sit on top of its
    /// surface — Deep Forest's green landed ΔE 5.6 from its green card and
    /// simply vanished. The offender steps clear, upward on a dark theme and
    /// downward on a light one, since that is the direction each has chroma
    /// in. Only a slot that actually collides moves; the rest keep the shared
    /// lightness that makes the set read as a set.
    private static func plateClear(of surface: String, at plate: LabColorMath.LCh) -> LabColorMath.LCh {
        var candidate = plate
        let surfaceLightness = LabColorMath.lch(of: surface).lightness
        let direction: Double = surfaceLightness < 50 ? 1 : -1
        var step = 0.0
        while LabColorMath.distance(surface, LabColorMath.hex(candidate)) < 12, step < 30 {
            step += 2
            candidate.lightness = plate.lightness + direction * step
            candidate.chroma = min(28, LabColorMath.maxChroma(lightness: candidate.lightness,
                                                              hue: plate.hue))
        }
        return candidate
    }

    /// The fifth slot: the theme's selection color, a touch deeper.
    ///
    /// A theme that never pins a selection inherits its cursor, which is a
    /// vivid accent — soyehtDark's is a green at L* 62, and the near-white ink
    /// on top of it reads at 1.2:1. So the deepening continues past the first
    /// three points if it has to, until the name is legible; if the hue cannot
    /// get there at all, the slot joins the tetrad's lightness and keeps only
    /// its hue.
    private static func readableSelectionPlate(
        _ selection: LabColorMath.LCh,
        ink: String,
        fallback: Double
    ) -> LabColorMath.LCh {
        var candidate = selection
        var step = 3.0
        while step <= 60 {
            candidate.lightness = max(6, selection.lightness - step)
            let hex = LabColorMath.hex(candidate)
            if LabColorMath.contrastRatio(ink, hex) >= 4.5 { return candidate }
            step += 4
        }
        candidate.lightness = fallback
        return candidate
    }

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
