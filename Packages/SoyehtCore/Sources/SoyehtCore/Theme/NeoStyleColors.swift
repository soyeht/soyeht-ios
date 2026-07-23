import Foundation

/// Neumorphism-specific color roles.
///
/// Neumorphic depth comes from a raised surface near the background color plus
/// a pair of soft shadows (dark cast down-right, light cast up-left) and
/// recessed "wells". These roles don't exist in `SoyehtAppPalette`, so they are
/// derived here from the chrome background — or taken verbatim from a curated
/// preset via reserved `extraHexColors` keys (`neo.surface`, `neo.well`,
/// `neo.shadowDark`, `neo.shadowLight`, `neo.accentShadow`).
public struct NeoStyleColors: Equatable, Sendable {
    public let raisedSurfaceHex: String
    public let wellHex: String
    public let shadowDarkHex: String
    public let shadowLightHex: String
    /// Colored glow behind accent-filled elements. Stored opaque; apply
    /// alpha (~0.35) at the call site.
    public let accentShadowHex: String

    public init(theme: TerminalColorTheme) {
        let palette = theme.appPalette
        let extra = theme.extraHexColors
        let background = palette.backgroundHex
        let isDark = palette.isDark

        raisedSurfaceHex = extra["neo.surface"]
            ?? (isDark ? HexColorMath.lighten(background, by: 0.04)
                       : HexColorMath.lighten(background, by: 0.35))
        wellHex = extra["neo.well"]
            ?? HexColorMath.darken(background, by: isDark ? 0.18 : 0.06)
        shadowDarkHex = extra["neo.shadowDark"]
            ?? HexColorMath.darken(background, by: isDark ? 0.45 : 0.26)
        shadowLightHex = extra["neo.shadowLight"]
            ?? (isDark ? HexColorMath.lighten(background, by: 0.08) : "#FFFFFF")
        accentShadowHex = extra["neo.accentShadow"] ?? palette.accentHex
    }
}

public extension TerminalColorTheme {
    var neoStyleColors: NeoStyleColors {
        NeoStyleColors(theme: self)
    }
}
