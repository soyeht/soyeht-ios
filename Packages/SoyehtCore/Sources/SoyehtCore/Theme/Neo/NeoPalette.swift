import SwiftUI

/// The colours a neumorphic surface needs, read from a theme and never
/// computed.
///
/// Every value comes from `NeoStyleColors` (the reserved `neo.*` keys) or from
/// the theme's app palette. Deriving them — lighten the background by this,
/// darken by that — is what used to restyle approved themes whenever a
/// constant moved, so this type only ever reads.
public struct NeoPalette: Equatable, Sendable {
    public let canvas: Color
    public let face: Color
    public let well: Color

    public let text: Color
    public let textSecondary: Color
    public let muted: Color

    public let accent: Color
    public let onAccent: Color
    public let accentGlow: Color

    public let shadowDark: Color
    public let shadowLight: Color
    public let wellShadow: Color
    public let wellRim: Color
    /// A hard one-point line along the well's top-left inner edge. Only dark
    /// faces declare one; `nil` on a light face, where the rim already reads
    /// as an edge.
    public let wellLip: Color?

    public let success: Color
    public let danger: Color

    public init(theme: TerminalColorTheme) {
        let neo = theme.neoStyleColors
        let app = theme.appPalette

        canvas = Color(hex: app.backgroundHex)
        face = Color(hex: neo.raisedSurfaceHex)
        well = Color(hex: neo.wellHex)

        text = Color(hex: app.textPrimaryHex)
        textSecondary = Color(hex: app.textSecondaryHex)
        muted = Color(hex: app.textMutedHex)

        accent = Color(hex: app.accentHex)
        onAccent = Color(hex: app.buttonTextOnAccentHex)
        accentGlow = Color(hex: neo.accentShadowHex)

        shadowDark = Color(hex: neo.shadowDarkHex)
        shadowLight = Color(hex: neo.shadowLightHex)
        wellShadow = Color(hex: neo.wellShadowHex)
        wellRim = Color(hex: neo.wellRimHex)
        wellLip = neo.wellLipHex.map { Color(hex: $0) }

        success = Color(hex: app.successHex)
        danger = Color(hex: app.dangerHex)
    }

    /// The palette onboarding pins. Setup runs in Neo Milk whatever style the
    /// app is in, so a first launch never shows a half-styled window and a
    /// classic user's Welcome does not change under them mid-flow.
    public static let cloud = NeoPalette(theme: .neoMilk)

    /// The palette a neo surface inside the running app uses: whatever the
    /// active theme states.
    public static var active: NeoPalette {
        NeoPalette(theme: TerminalThemeStore.shared.activeTheme)
    }
}
