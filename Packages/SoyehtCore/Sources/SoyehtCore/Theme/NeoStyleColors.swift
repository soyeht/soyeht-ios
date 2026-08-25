import Foundation

/// Neumorphism-specific colour roles: the raised surface, the recessed well,
/// the light/dark shadow pair and the accent glow.
///
/// **Every one of these is read, never computed.** A theme states them under
/// the reserved `neo.*` keys and this type hands them back.
///
/// They used to be derived from the chrome background — lighten by 0.35, darken
/// by 0.26, and so on — for any theme that did not pin them. Five themes never
/// pinned them, so each adjustment to those constants restyled themes whose
/// colours had been chosen and approved, with nothing in the code or the tests
/// marking it as a change. Approved colour is data. A theme that ships without
/// these keys gets the neutral fallback below, which reads nothing from the
/// theme and so cannot drift with it.
public struct NeoStyleColors: Equatable, Sendable {
    public let raisedSurfaceHex: String
    public let wellHex: String
    public let shadowDarkHex: String
    public let shadowLightHex: String
    /// Colored glow behind accent-filled elements. Stored opaque; apply
    /// alpha (~0.35) at the call site.
    public let accentShadowHex: String

    public init(theme: TerminalColorTheme) {
        let extra = theme.extraHexColors
        raisedSurfaceHex = extra["neo.surface"] ?? Self.fallback.surface
        wellHex = extra["neo.well"] ?? Self.fallback.well
        shadowDarkHex = extra["neo.shadowDark"] ?? Self.fallback.shadowDark
        shadowLightHex = extra["neo.shadowLight"] ?? Self.fallback.shadowLight
        accentShadowHex = extra["neo.accentShadow"] ?? theme.appPalette.accentHex
    }

    /// Used only by a theme that states none of its own — an imported or user
    /// theme. Fixed, and identical for every such theme.
    static let fallback = (
        surface: "#31333E", well: "#21222C",
        shadowDark: "#16171E", shadowLight: "#393B46"
    )
}

public extension TerminalColorTheme {
    var neoStyleColors: NeoStyleColors {
        NeoStyleColors(theme: self)
    }
}
