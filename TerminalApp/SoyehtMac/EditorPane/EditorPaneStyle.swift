import AppKit
import Foundation
import SoyehtCore

/// Editor palette derived from the user's active `TerminalColorTheme`
/// (iTerm2-Color-Schemes catalog). All tokens flow through `MacTheme` so
/// the editor follows whatever theme the user picked in Preferences →
/// Appearance, and recomputes on `.preferencesDidChange`.
///
/// `chrome` is intentionally a subtle lift/recess from `surface` so the
/// sidebar, tab strip and footer read as a separate plane from the editor
/// body. The shift is small enough that text contrast stays stable.
enum EditorPaneDesign {
    static var surface: NSColor { MacTheme.surfaceBase }
    static var surfaceDeep: NSColor { MacTheme.surfaceBase }
    static var surfaceRaised: NSColor { MacTheme.tabActiveFill }
    static var selected: NSColor { MacTheme.selection }
    static var currentLine: NSColor { MacTheme.surfaceBase }
    static var border: NSColor { MacTheme.borderIdle }
    static var text: NSColor { MacTheme.readableTextOnBackground }
    static var muted: NSColor { MacTheme.readableSecondaryTextOnBackground }
    static var dim: NSColor { MacTheme.readableSecondaryTextOnBackground }
    static var blue: NSColor { MacTheme.accentBlue }
    static var orange: NSColor { MacTheme.accentAmber }
    static var yellow: NSColor { MacTheme.accentAmber }
    static var green: NSColor { MacTheme.accentGreenEmerald }
    static var red: NSColor { MacTheme.accentRed }

    /// Lifted/recessed surface for sidebar + tab strip + footer.
    static var chrome: NSColor {
        let base = MacTheme.surfaceBase
        let palette = TerminalColorTheme.active.appPalette
        let target: NSColor = palette.isDark ? .white : .black
        let fraction: CGFloat = palette.isDark ? 0.06 : 0.04
        return base.blended(withFraction: fraction, of: target) ?? base
    }
}

/// NSView subclass that registers an `.arrow` cursor rect for its bounds.
/// Editor chrome root: typealias to the shared `MacCursor.ChromeView`.
typealias ArrowCursorView = MacCursor.ChromeView

extension String.Encoding {
    var localizedName: String? {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        default: return nil
        }
    }
}
