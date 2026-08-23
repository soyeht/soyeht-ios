import Foundation

/// The colors that tell one agent's pane from another's: the plate its name
/// sits on in the pane header.
///
/// This lives in the core rather than in `MacTheme` because it needs to be the
/// thing the tests actually run. It was AppKit-side, mirrored by a
/// reimplementation in the test suite, and the two silently drifted — the
/// plate's lightness floor reached the mirror and never reached the app, so
/// the tests went green while the app shipped the exact colors the floor was
/// added to fix.
public enum AgentIdentityPalette {
    /// Violet, rose, green, cyan. FIXED, and in this order on every theme, so
    /// an agent keeps its color when the theme changes — which is what lets
    /// the color mean the agent rather than the theme.
    ///
    /// Two earlier versions anchored these on each theme's accent, and both
    /// were wrong the same way: anchoring rotates the sequence, so the order
    /// came out different per theme. It only looked right where a theme's
    /// accent happened to land on these four.
    public static let hues: [Double] = [317, 7, 137, 187]

    /// How many slots a theme carries: the four hues plus the theme's own.
    public static var slotCount: Int { hues.count + 1 }

    /// The five plates for a theme, in order.
    ///
    /// What follows the theme is the TONE, not the hue. Lightness and chroma
    /// sit in the theme's own register, so the same violet is a pale lilac on
    /// a light theme and a deep plum on a dark one, and all four share that
    /// register — which is what makes them read as one set rather than four
    /// unrelated colors.
    public static func plates(for palette: SoyehtAppPalette) -> [String] {
        let surface = LabColorMath.lch(of: palette.surfaceHex)
        let lightness = plateLightness(surface: surface.lightness)
        // One chroma every hue can actually reach, so the set reads as
        // siblings instead of one washed-out member beside three vivid ones.
        let chroma = min(28, hues.map {
            LabColorMath.maxChroma(lightness: lightness, hue: $0)
        }.min() ?? 28)

        let four = hues.map { hue in
            LabColorMath.hex(clearOfSurface(
                palette.surfaceHex,
                plate: LabColorMath.LCh(lightness: lightness, chroma: chroma, hue: hue)
            ))
        }
        return four + [themeSlot(palette, fallback: lightness)]
    }

    /// The plate sinks 9 L* below the card — enough to read as something the
    /// name rests on rather than a lit bar. An earlier version sank 5 at a
    /// chroma of 10 and had effectively vanished; the header became a band of
    /// text with no pill at all, which is what lost the agent's identity.
    /// Contrast was never the problem there, measuring 6:1 to 12:1 throughout.
    ///
    /// It never sinks past L* 19. Deeper than that the plates go muddy: the
    /// two dark themes that read worst sat at L* 14 and 16, and the two that
    /// read well at 19.8 and 21.7.
    ///
    /// A surface too dark to sink into steps up instead, to where color starts
    /// to be possible at all — pure black holds no hue, and a flat step landed
    /// at L* 8, where five slots collapse into one.
    static func plateLightness(surface: Double) -> Double {
        let sunk = surface - 9
        return sunk >= 12 ? max(sunk, 19) : max(surface + 8, 18)
    }

    /// A plate whose hue is the theme's own hue sits on top of its card and
    /// disappears — a green theme's green slot measured ΔE 5.6 against its own
    /// surface. It steps clear: upward on a dark theme, downward on a light
    /// one, since that is the direction each has chroma in. Moving it simply
    /// "away" from the surface is wrong, because for a sunk plate that means
    /// further into the mud it is being rescued from.
    ///
    /// Only a colliding slot moves. The rest keep the shared lightness.
    private static func clearOfSurface(_ surface: String, plate: LabColorMath.LCh) -> LabColorMath.LCh {
        var candidate = plate
        let direction: Double = LabColorMath.lch(of: surface).lightness < 50 ? 1 : -1
        var step = 0.0
        while LabColorMath.distance(surface, LabColorMath.hex(candidate)) < 12, step < 30 {
            step += 2
            candidate.lightness = plate.lightness + direction * step
            candidate.chroma = min(28, LabColorMath.maxChroma(
                lightness: candidate.lightness, hue: plate.hue))
        }
        return candidate
    }

    /// The fifth slot: the theme's own selection color, a touch deeper. It is
    /// the only slot whose hue comes from the theme, which is why it is the
    /// one a pane wears by default.
    ///
    /// A theme that never pins a selection inherits its cursor, which is a
    /// vivid accent: one house theme's is a green at L* 62, and near-white ink
    /// on it reads at 1.2:1. So the deepening continues past the first three
    /// points until the name is legible, and if the hue cannot get there at
    /// all the slot falls back to the others' lightness, keeping only its hue.
    private static func themeSlot(_ palette: SoyehtAppPalette, fallback: Double) -> String {
        var candidate = LabColorMath.lch(of: palette.selectionHex)
        let seed = candidate.lightness
        var step = 3.0
        while step <= 60 {
            candidate.lightness = max(6, seed - step)
            let hex = LabColorMath.hex(candidate)
            if LabColorMath.contrastRatio(palette.textPrimaryHex, hex) >= 4.5 { return hex }
            step += 4
        }
        candidate.lightness = fallback
        return LabColorMath.hex(candidate)
    }
}
