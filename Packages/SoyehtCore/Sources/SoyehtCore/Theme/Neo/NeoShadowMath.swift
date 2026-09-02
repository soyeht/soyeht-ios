import CoreGraphics

/// One conversion, shared by AppKit and SwiftUI.
///
/// A design states a shadow in CSS `box-shadow` terms. CSS blurs with a
/// standard deviation of blur/2; CALayer's `shadowRadius` and SwiftUI's
/// `.shadow(radius:)` blur with the radius itself. Reading a blur off the
/// design and passing it as a radius renders every shadow at twice the
/// softness it was drawn at — the mush. `MacSurface.Shadow.neo` already did
/// this division; now both platforms call the same function so they cannot
/// drift apart.
public enum NeoShadowMath {
    public static func renderRadius(blur: CGFloat) -> CGFloat { blur / 2 }
}

/// The (offset, blur) pairs, chosen by how much SPACE surrounds the element,
/// not by how big the element is. Reach — offset plus blur — has to fit in the
/// margin available, or the shadow is sliced off with a straight edge.
public enum NeoElevation: Equatable, Sendable, CaseIterable {
    /// A word well or a small chip in a tight grid.
    case chip
    /// A card in a grid with a normal corridor between cards.
    case card
    /// A pill button standing on its own.
    case pill
    /// A panel that owns most of its window.
    case panel
    /// A solitary hero object.
    case hero

    public var offset: CGFloat {
        switch self {
        case .chip: return 3
        case .card: return 4
        case .pill: return 6
        case .panel: return 9
        case .hero: return 12
        }
    }

    public var blur: CGFloat {
        switch self {
        case .chip: return 5
        case .card: return 8
        case .pill: return 10
        case .panel: return 18
        case .hero: return 24
        }
    }

    /// What the shadow needs on every side. Compare against the margin before
    /// choosing an elevation.
    public var reach: CGFloat { offset + blur }

    public var renderRadius: CGFloat { NeoShadowMath.renderRadius(blur: blur) }
}

/// The corner radii of the style, the same numbers `MacSurface.RadiusSpec`
/// states for AppKit.
public enum NeoRadius {
    public static let card: CGFloat = 20
    public static let control: CGFloat = 12
    public static let pill: CGFloat = 999
}
