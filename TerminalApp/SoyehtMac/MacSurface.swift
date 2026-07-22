import AppKit
import SwiftUI
import SoyehtCore

/// macOS shape & elevation tokens.
///
/// Semantic corner-radius, border-width and shadow roles for app chrome,
/// sibling to `MacTheme` (color) and `MacTypography` (type). The design-style
/// system reads shape from here so swapping a style restyles every surface at
/// once. Terminal glyph content is unaffected — these tokens stop at pane
/// chrome.
enum MacSurface {

    // MARK: - Corner radius

    enum Radius {
        /// Tiny status dots and mini badges (editor dirty dot, git selection badge).
        static let indicator: CGFloat = 3
        /// Count badges and transient overlay labels.
        static let badge: CGFloat = 4
        /// Small chips and floating pane controls.
        static let chip: CGFloat = 5
        /// Buttons, inputs, list rows, small tiles — the compact workhorse.
        static let control: CGFloat = 6
        /// Voice input capsule.
        static let inputCapsule: CGFloat = 7
        /// Cards, thumbnails, QR images — the large workhorse.
        static let card: CGFloat = 8
        /// Boxed feature panels (safety-code display, security-code box).
        static let panel: CGFloat = 10
        /// Window chrome root corner.
        static let window: CGFloat = 12
        /// Hero/media clips inside cards.
        static let mediaLarge: CGFloat = 12
        /// Detached popover cards (QR handoff).
        static let popover: CGFloat = 14
        /// Full-bleed hero media (continuity camera).
        static let hero: CGFloat = 20
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
    /// one-liners so a style can later swap specs wholesale.
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
        /// Workspace tab lifted out of the strip while dragging.
        static var tabLift: Shadow {
            Shadow(color: MacTheme.surfaceDeep, opacity: 1, offset: CGSize(width: 0, height: -8), radius: 24)
        }
        /// Floating sidebar panel casting right onto the workspace.
        static var floatingPanel: Shadow {
            Shadow(color: MacTheme.surfaceDeep, opacity: 1, offset: CGSize(width: 4, height: 0), radius: 20)
        }
        /// Claw drawer casting left onto the workspace.
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
