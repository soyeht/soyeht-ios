import AppKit
import SwiftUI
import SoyehtCore

/// macOS shape & elevation tokens.
///
/// Semantic corner-radius, border-width and shadow roles for app chrome,
/// sibling to `MacTheme` (color) and `MacTypography` (type). Every token
/// resolves through the active `DesignStyle`, so switching styles restyles
/// every surface at once. Terminal glyph content is unaffected — these
/// tokens stop at pane chrome.
enum MacSurface {

    static var style: DesignStyle { DesignStyle.active }

    // MARK: - Corner radius

    /// Per-style radius values. Classic carries the app's historical
    /// metrics; neomorphic follows the Pencil neo reference (larger, softer).
    private struct RadiusSpec {
        var indicator: CGFloat
        var badge: CGFloat
        var chip: CGFloat
        var control: CGFloat
        var inputCapsule: CGFloat
        var card: CGFloat
        var panel: CGFloat
        var window: CGFloat
        var mediaLarge: CGFloat
        var popover: CGFloat
        var hero: CGFloat

        static let classic = RadiusSpec(
            indicator: 3, badge: 4, chip: 5, control: 6, inputCapsule: 7,
            card: 8, panel: 10, window: 12, mediaLarge: 12, popover: 14, hero: 20
        )
        static let neomorphic = RadiusSpec(
            indicator: 3, badge: 6, chip: 8, control: 12, inputCapsule: 12,
            card: 16, panel: 18, window: 20, mediaLarge: 16, popover: 18, hero: 24
        )
    }

    private static var radii: RadiusSpec {
        switch style {
        case .classic, .neubrutalist: return .classic
        case .neomorphic: return .neomorphic
        }
    }

    enum Radius {
        /// Tiny status dots and mini badges (editor dirty dot, git selection badge).
        static var indicator: CGFloat { radii.indicator }
        /// Count badges and transient overlay labels.
        static var badge: CGFloat { radii.badge }
        /// Small chips and floating pane controls.
        static var chip: CGFloat { radii.chip }
        /// Buttons, inputs, list rows, small tiles — the compact workhorse.
        static var control: CGFloat { radii.control }
        /// Voice input capsule.
        static var inputCapsule: CGFloat { radii.inputCapsule }
        /// Cards, thumbnails, QR images — the large workhorse.
        static var card: CGFloat { radii.card }
        /// Boxed feature panels (safety-code display, security-code box).
        static var panel: CGFloat { radii.panel }
        /// Window chrome root corner.
        static var window: CGFloat { radii.window }
        /// Hero/media clips inside cards.
        static var mediaLarge: CGFloat { radii.mediaLarge }
        /// Detached popover cards (QR handoff).
        static var popover: CGFloat { radii.popover }
        /// Full-bleed hero media (continuity camera).
        static var hero: CGFloat { radii.hero }
        /// Fully-rounded pills (neo chrome chips, tab pills).
        static var pill: CGFloat { 999 }
    }

    // MARK: - Border width

    enum Border {
        /// Half-point separator between inactive editor tabs.
        static let divider: CGFloat = 0.5
        /// Standard 1pt outline for cards, rows and inputs.
        static let hairline: CGFloat = 1
        /// Slightly heavier outline for emphasis states.
        static let emphasis: CGFloat = 1.5
        /// Focus/glow ring (safety-code active state).
        static let focusRing: CGFloat = 2
    }

    // MARK: - Shadows

    /// A complete layer shadow spec. `apply(to:)`/`clear(_:)` keep call sites
    /// one-liners so a style can swap specs wholesale. Offsets are in
    /// unflipped AppKit layer coordinates (negative height casts downward).
    struct Shadow {
        var color: NSColor
        var opacity: Float
        var offset: CGSize
        var radius: CGFloat

        func apply(to layer: CALayer?) {
            guard let layer else { return }
            layer.shadowColor = color.cgColor
            layer.shadowOpacity = opacity
            layer.shadowOffset = offset
            layer.shadowRadius = radius
        }

        static func clear(_ layer: CALayer?) {
            guard let layer else { return }
            layer.shadowOpacity = 0
            layer.shadowColor = nil
            layer.shadowOffset = .zero
            layer.shadowRadius = 0
        }
    }

    enum Shadows {
        private static var neo: Bool { style == .neomorphic }

        // Canonical neumorphism (Malewicz recipe): light source top-left, no
        // exceptions; dark shadow = background-tinted solid cast down-right,
        // light shadow = white-ish solid cast up-left; blur ≈ 2× offset;
        // FULL opacity — softness comes from the shadow color sitting close
        // to the background, never from low alpha. Offsets are in unflipped
        // AppKit layer coordinates (negative height casts downward).

        /// Dual pair for floating panels (sidebar, drawer). 9pt offset /
        /// 18pt blur — the classic "9px 9px 18px" raised-card recipe, right
        /// for isolated surfaces with lots of canvas around them.
        static var neoDark: Shadow {
            Shadow(color: MacTheme.neoShadowDark, opacity: 1, offset: CGSize(width: 9, height: -9), radius: 18)
        }
        static var neoLight: Shadow {
            Shadow(color: MacTheme.neoShadowLight, opacity: 1, offset: CGSize(width: -9, height: 9), radius: 18)
        }

        /// Dual pair for pane cards in the grid. Tighter 5pt/10pt (the Pencil
        /// reference's own pane values): in a ~20pt inter-card gap the larger
        /// recipe shows only the flat middle of the shadow — this one shows
        /// the falloff, which is what reads as "soft".
        static var neoDarkPane: Shadow {
            Shadow(color: MacTheme.neoShadowDark, opacity: 1, offset: CGSize(width: 5, height: -5), radius: 10)
        }
        static var neoLightPane: Shadow {
            Shadow(color: MacTheme.neoShadowLight, opacity: 1, offset: CGSize(width: -5, height: 5), radius: 10)
        }

        /// Dual pair for compact controls (chips, pills, small buttons):
        /// 4pt offset / 8pt blur, same 2× ratio.
        static var neoDarkSmall: Shadow {
            Shadow(color: MacTheme.neoShadowDark, opacity: 1, offset: CGSize(width: 4, height: -4), radius: 8)
        }
        static var neoLightSmall: Shadow {
            Shadow(color: MacTheme.neoShadowLight, opacity: 1, offset: CGSize(width: -4, height: 4), radius: 8)
        }

        /// Generic raised surface (pane cards). Empty in classic (flat
        /// chrome); the neumorphic dual pair when neo is active. Render via
        /// `MacStyledSurfaceView` — plain CALayers hold one shadow only.
        static var raisedSet: [Shadow] {
            neo ? [neoDarkPane, neoLightPane] : []
        }

        /// Compact raised controls (chips, pills).
        static var raisedSmallSet: [Shadow] {
            neo ? [neoDarkSmall, neoLightSmall] : []
        }

        /// Slightly tighter pair for the active (pressed-looking) tab pill.
        static var raisedTabSet: [Shadow] {
            neo ? [
                Shadow(color: MacTheme.neoShadowDark, opacity: 1, offset: CGSize(width: 3, height: -3), radius: 6),
                Shadow(color: MacTheme.neoShadowLight, opacity: 1, offset: CGSize(width: -3, height: 3), radius: 6),
            ] : []
        }

        /// Colored glow behind accent-filled pills (the Claws button).
        static var accentGlowSet: [Shadow] {
            neo ? [
                Shadow(color: MacTheme.neoAccentShadow.withAlphaComponent(0.35), opacity: 1, offset: CGSize(width: 5, height: -5), radius: 12),
            ] : []
        }

        /// Floating sidebar panel. Classic casts right onto the workspace;
        /// neo lifts with the standard dual pair.
        static var sidebarPanelSet: [Shadow] {
            neo ? [neoDark, neoLight] : [floatingPanel]
        }

        /// Claw drawer panel (mirrors the sidebar horizontally — it hangs on
        /// the right edge, so its dark cast leans left but light still comes
        /// from the top-left).
        static var drawerPanelSet: [Shadow] {
            neo ? [
                Shadow(color: MacTheme.neoShadowDark, opacity: 1, offset: CGSize(width: -9, height: -9), radius: 18),
                Shadow(color: MacTheme.neoShadowLight, opacity: 1, offset: CGSize(width: -2, height: 9), radius: 18),
            ] : [drawerPanel]
        }

        /// Workspace tab lifted out of the strip while dragging.
        static var tabLift: Shadow {
            neo
                ? Shadow(color: MacTheme.neoShadowDark, opacity: 1, offset: CGSize(width: 0, height: -8), radius: 16)
                : Shadow(color: MacTheme.surfaceDeep, opacity: 1, offset: CGSize(width: 0, height: -8), radius: 24)
        }
        /// Floating sidebar panel casting right onto the workspace (classic).
        static var floatingPanel: Shadow {
            Shadow(color: MacTheme.surfaceDeep, opacity: 1, offset: CGSize(width: 4, height: 0), radius: 20)
        }
        /// Claw drawer casting left onto the workspace (classic).
        static var drawerPanel: Shadow {
            Shadow(color: MacTheme.surfaceDeep, opacity: 1, offset: CGSize(width: -4, height: 0), radius: 20)
        }
        /// Voice input button resting glow (opacity animates with audio level).
        static var voiceButton: Shadow {
            Shadow(color: .black, opacity: 0.18, offset: CGSize(width: 0, height: -1), radius: 8)
        }
        /// Drag ghost while reordering editor tabs.
        static var dragGhost: Shadow {
            Shadow(color: .black, opacity: 0.24, offset: CGSize(width: 0, height: 4), radius: 10)
        }
    }
}
