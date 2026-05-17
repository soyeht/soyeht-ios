import AppKit
import SoyehtCore

/// Git pane palette derived from the active terminal theme so it tracks
/// `MacTheme` and `TerminalPreferences.fontSize`, matching the editor pane.
enum GitPaneDesign {
    static var chrome: NSColor       { MacTheme.paneHeaderNew }
    static var surface: NSColor      { MacTheme.surfaceBase }
    static var surfaceDeep: NSColor  { MacTheme.surfaceBase }
    static var surfaceRaised: NSColor { MacTheme.tabActiveFill }
    static var selected: NSColor     { MacTheme.selection }
    static var border: NSColor       { MacTheme.borderIdle }
    static var text: NSColor         { MacTheme.readableTextOnBackground }
    static var brightText: NSColor   { MacTheme.readableTextOnBackground }
    static var muted: NSColor        { MacTheme.readableSecondaryTextOnBackground }
    static var dim: NSColor          { MacTheme.readableSecondaryTextOnBackground }
    static var blue: NSColor         { MacTheme.accentBlue }
    static var hunkBlue: NSColor     { MacTheme.accentBlue }
    static var yellow: NSColor       { MacTheme.accentAmber }
    static var branchYellow: NSColor { MacTheme.accentAmber }
    static var green: NSColor        { MacTheme.accentGreenEmerald }
    static var greenText: NSColor    { MacTheme.accentGreenEmerald }
    static var red: NSColor          { MacTheme.accentRed }
    static var redText: NSColor      { MacTheme.accentRed }
    static var greenBackground: NSColor { MacTheme.accentGreenEmerald.withAlphaComponent(0.16) }
    static var redBackground: NSColor   { MacTheme.accentRed.withAlphaComponent(0.16) }
    static var hunkBackground: NSColor  { MacTheme.accentBlue.withAlphaComponent(0.10) }
    static var badgeBackground: NSColor { MacTheme.tabActiveFill }
}

/// Font sizing derived from the user's terminal preferences so the git
/// pane scales with the editor body.
enum GitPaneTypography {
    static var bodySize: CGFloat   { max(9, TerminalPreferences.shared.fontSize) }
    static var chromeSize: CGFloat { max(9, TerminalPreferences.shared.fontSize * 0.85) }
    static var smallSize: CGFloat  { max(8, TerminalPreferences.shared.fontSize * 0.75) }

    static func body(_ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: bodySize, weight: weight)
    }

    static func chrome(_ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: chromeSize, weight: weight)
    }

    static func small(_ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: smallSize, weight: weight)
    }
}
