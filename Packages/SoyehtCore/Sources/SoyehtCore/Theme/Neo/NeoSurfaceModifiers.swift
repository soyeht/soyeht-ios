import SwiftUI

/// The three surfaces of the style: the canvas everything sits on, a face that
/// rises out of it, and a well that sinks into it.
///
/// Two rules decide whether it reads as one material or as stickers:
///
/// 1. **The light comes from the top-left, always.** The dark side falls to
///    the bottom-right, the lit side to the top-left. SwiftUI's y axis points
///    down, so that is `(+d, +d)` for the dark shadow and `(−d, −d)` for the
///    light one — the opposite signs from the CALayer code, which is not
///    flipped.
/// 2. **The tinted pair is opaque.** Softness comes from choosing a shadow
///    colour near the canvas, never from lowering alpha. A translucent shadow
///    over another surface turns into a grey smear.
///
/// Both shadows are applied AFTER `.clipShape`, on a `.compositingGroup()`.
/// Clipping first would cut them off at the shape's edge and leave a dry 1px
/// transition — the macOS 14 trap that `cornerRadius` on a backing layer sets
/// on the AppKit side.
public extension View {
    /// The ground. Everything neo sits on this and nothing else.
    func neoCanvas(_ palette: NeoPalette) -> some View {
        background(palette.canvas)
    }

    /// A face standing above the canvas.
    func neoRaised(
        _ palette: NeoPalette,
        radius: CGFloat = NeoRadius.card,
        elevation: NeoElevation = .card
    ) -> some View {
        modifier(NeoRaised(palette: palette, radius: radius, elevation: elevation, inverted: false))
    }

    /// The same face pressed in — the pair swaps sides. Use for the pressed
    /// state of a control, never as a resting style.
    func neoPressed(
        _ palette: NeoPalette,
        radius: CGFloat = NeoRadius.control,
        elevation: NeoElevation = .chip
    ) -> some View {
        modifier(NeoRaised(palette: palette, radius: radius, elevation: elevation, inverted: true))
    }

    /// A cavity in the canvas: the shadow falls INSIDE the shape. Text fields,
    /// word wells, progress tracks.
    func neoWell(
        _ palette: NeoPalette,
        radius: CGFloat = NeoRadius.control,
        depth: CGFloat = 3
    ) -> some View {
        modifier(NeoWell(palette: palette, radius: radius, depth: depth))
    }

    /// The coloured halo under an accent-filled control. Alpha belongs here,
    /// not in the token.
    func neoAccentGlow(_ palette: NeoPalette, elevation: NeoElevation = .pill) -> some View {
        shadow(
            color: palette.accentGlow.opacity(0.35),
            radius: elevation.renderRadius,
            x: elevation.offset * 0.8,
            y: elevation.offset * 0.8
        )
    }
}

private struct NeoRaised: ViewModifier {
    let palette: NeoPalette
    let radius: CGFloat
    let elevation: NeoElevation
    let inverted: Bool

    func body(content: Content) -> some View {
        let d = inverted ? -elevation.offset : elevation.offset
        return content
            .background(palette.face)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .compositingGroup()
            .shadow(color: palette.shadowDark, radius: elevation.renderRadius, x: d, y: d)
            .shadow(color: palette.shadowLight, radius: elevation.renderRadius, x: -d, y: -d)
    }
}

private struct NeoWell: ViewModifier {
    let palette: NeoPalette
    let radius: CGFloat
    let depth: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                shape.fill(
                    palette.well
                        .shadow(.inner(color: palette.wellShadow, radius: depth, x: depth, y: depth))
                        .shadow(.inner(color: palette.wellRim, radius: depth, x: -depth, y: -depth))
                )
                .overlay {
                    // Only a dark face declares a lip; on a light one the rim
                    // already reads as an edge.
                    if let lip = palette.wellLip {
                        shape.strokeBorder(lip, lineWidth: 1)
                    }
                }
            }
            .clipShape(shape)
    }
}
