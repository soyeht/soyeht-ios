import Foundation
import Testing
@testable import SoyehtCore

@Suite("LabColorMath")
struct LabColorMathTests {
    @Test func lightnessMatchesKnownAnchors() {
        #expect(abs(LabColorMath.lch(of: "#FFFFFF").lightness - 100) < 0.2)
        #expect(abs(LabColorMath.lch(of: "#000000").lightness) < 0.2)
        // Middle grey sits near L* 53, not 50 — the classic sRGB gamma gap.
        #expect(abs(LabColorMath.lch(of: "#808080").lightness - 53.6) < 0.5)
    }

    @Test func neutralsCarryNoChroma() {
        for grey in ["#000000", "#404040", "#808080", "#C0C0C0", "#FFFFFF"] {
            #expect(LabColorMath.lch(of: grey).chroma < 0.5, "\(grey) is not neutral")
        }
    }

    @Test func roundTripsThroughLCh() {
        for hex in ["#EDB964", "#062635", "#5B7CFA", "#223D22", "#C0C8CA"] {
            let restored = LabColorMath.hex(LabColorMath.lch(of: hex))
            let (r1, g1, b1) = ColorTheme.rgb8(from: hex)
            let (r2, g2, b2) = ColorTheme.rgb8(from: restored)
            let drift = max(abs(Int(r1) - Int(r2)), abs(Int(g1) - Int(g2)), abs(Int(b1) - Int(b2)))
            #expect(drift <= 1, "\(hex) round-tripped to \(restored)")
        }
    }

    /// The reason this type exists: an sRGB channel scale drags chroma along
    /// with the lightness, so a darkened saturated surface drifts grey and a
    /// shadow stops looking like the same material under less light.
    @Test func lightnessChangeKeepsChromaThatChannelScalingLoses() {
        let gold = "#EDB964"
        let source = LabColorMath.lch(of: gold)
        let target = source.lightness - 20

        let viaLab = LabColorMath.lch(of: LabColorMath.withLightness(gold, target))
        #expect(abs(viaLab.lightness - target) < 1.0)
        #expect(abs(viaLab.chroma - source.chroma) < 2.0, "Lab path lost chroma")
        #expect(abs(viaLab.hue - source.hue) < 2.0, "Lab path shifted hue")

        let viaScale = LabColorMath.lch(of: HexColorMath.darken(gold, by: 0.32))
        #expect(source.chroma - viaScale.chroma > 8.0, "channel scaling no longer bleeds chroma")
    }

    /// sRGB cannot hold every chroma at every lightness. An unreachable
    /// request must be reduced, never allowed to clip a channel — clipping
    /// silently returns a different hue than the one asked for.
    @Test func unreachableChromaIsClampedWithoutShiftingHue() {
        let request = LabColorMath.LCh(lightness: 85, chroma: 120, hue: 280)
        let produced = LabColorMath.lch(of: LabColorMath.hex(request))
        #expect(produced.chroma < 120)
        #expect(abs(produced.hue - 280) < 4.0, "clamping shifted the hue")
        #expect(abs(produced.lightness - 85) < 2.0)
    }
}

@Suite("Agent identity colors")
struct AgentIdentityTests {
    /// WCAG ratio. The palette keeps its own copy private, and widening that
    /// API just to assert on it would be the tail wagging the dog.
    static func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let (r, g, bl) = ColorTheme.rgb8(from: hex)
            func channel(_ value: UInt8) -> Double {
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(bl)
        }
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The shipped implementation, not a copy of it. A copy is what let the
    /// plate lightness floor land in the tests and never in the app.
    private func identity(for theme: TerminalColorTheme) -> [String] {
        AgentIdentityPalette.plates(for: theme.appPalette)
    }

    private func deltaE(_ a: String, _ b: String) -> Double {
        let x = LabColorMath.lch(of: a), y = LabColorMath.lch(of: b)
        let ax = x.chroma * cos(x.hue * .pi / 180), ay = x.chroma * sin(x.hue * .pi / 180)
        let bx = y.chroma * cos(y.hue * .pi / 180), by = y.chroma * sin(y.hue * .pi / 180)
        return ((x.lightness - y.lightness) * (x.lightness - y.lightness)
                + (ax - bx) * (ax - bx) + (ay - by) * (ay - by)).squareRoot()
    }

    /// The set exists to tell panes apart, so any two slots must be visibly
    /// different. Well above the ~2 unit threshold of perception, but not the
    /// 10 an earlier version asserted: that figure was only reachable by
    /// spreading the set across the whole hue wheel, which is exactly what
    /// pushed half of every theme's slots out of its tone. A dark face caps
    /// the chroma an analogous arc can carry, and 7 is what it buys.
    @Test func everySlotIsTellableFromEveryOther() {
        for theme in TerminalColorTheme.builtInThemes {
            let set = identity(for: theme)
            for i in set.indices {
                for j in set.indices where j > i {
                    #expect(deltaE(set[i], set[j]) > 7,
                            "\(theme.id) slots \(i) and \(j) are \(set[i]) and \(set[j])")
                }
            }
        }
    }

    /// The name sits on the plate, so it has to be readable on all five.
    ///
    /// Two tiers, because a plate can only ever sit between a theme's surface
    /// and its ink: Solarized pairs a mid-grey foreground with a dark ground
    /// at 4.6:1 to begin with, so nothing placed between them clears 4.5.
    /// The presets we author have the headroom and are held to it.
    @Test func theNameReadsOnEverySlot() {
        for theme in TerminalColorTheme.builtInThemes {
            let authored = theme.id.hasPrefix("neo")
            let floor = authored ? 4.5 : 3.5
            for plate in identity(for: theme) {
                #expect(Self.contrast(theme.appPalette.textPrimaryHex, plate) >= floor,
                        "\(theme.id) name on \(plate) is unreadable")
            }
        }
    }

    /// A plate is something the name rests on, never a light source: it sinks
    /// below the card on every theme with room to sink. Two exceptions, both
    /// forced. A surface too dark to sink into steps up to where color starts
    /// to exist — pure black holds no hue at all. And a slot whose hue is the
    /// theme's own hue has to clear its surface somehow, which on a dark theme
    /// means passing above it: Deep Forest's green would otherwise sit ΔE 5.6
    /// from its green card and vanish.
    @Test func platesSinkRatherThanGlow() {
        for theme in TerminalColorTheme.builtInThemes {
            let surface = LabColorMath.lch(of: theme.appPalette.surfaceHex).lightness
            let surfaceHue = LabColorMath.lch(of: theme.appPalette.surfaceHex).hue
            for plate in identity(for: theme).prefix(4) {
                let lightness = LabColorMath.lch(of: plate).lightness
                let hue = LabColorMath.lch(of: plate).hue
                let sharesTheSurfacesHue = abs(((hue - surfaceHue) + 180)
                    .truncatingRemainder(dividingBy: 360) - 180) < 30
                if sharesTheSurfacesHue { continue }
                if surface - 9 >= 12 {
                    #expect(lightness < surface, "\(theme.id) plate \(plate) outshines its card")
                } else {
                    #expect(lightness <= 26, "\(theme.id) plate \(plate) is a band, not a floor")
                }
            }
        }
    }

    /// The four arc slots share a lightness and a chroma — that shared
    /// footing is what makes them read as one palette.
    @Test func theArcSharesLightnessAndChroma() {
        for theme in TerminalColorTheme.builtInThemes {
            let four = identity(for: theme).prefix(4).map { LabColorMath.lch(of: $0) }
            let lightness = four.map(\.lightness)
            let chroma = four.map(\.chroma)
            let clash = LabColorMath.lch(of: theme.appPalette.surfaceHex).hue
            let escaped = four.filter {
                abs((($0.hue - clash) + 180).truncatingRemainder(dividingBy: 360) - 180) < 30
            }.count
            if escaped == 0 {
                #expect((lightness.max()! - lightness.min()!) < 1.5, "\(theme.id) lightness drifts")
                #expect((chroma.max()! - chroma.min()!) < 2.0, "\(theme.id) chroma drifts")
            }
        }
    }

    /// The hues are the same everywhere, so an agent keeps its color across
    /// themes. What varies is the tone, which each theme sets.
    @Test func theHuesAreStableAcrossThemes() {
        let reference = identity(for: TerminalColorTheme.neoMilk).prefix(4)
            .map { LabColorMath.lch(of: $0).hue }
        for theme in TerminalColorTheme.builtInThemes {
            for (expected, plate) in zip(reference, identity(for: theme).prefix(4)) {
                let hue = LabColorMath.lch(of: plate).hue
                let drift = abs(((hue - expected) + 180).truncatingRemainder(dividingBy: 360) - 180)
                // 5, not 0: reducing chroma to fit the gamut nudges the hue a
                // degree or two at the extremes of lightness. Imperceptible,
                // and the alternative is clipping a channel, which shifts it
                // much further.
                #expect(drift < 5, "\(theme.id) plate \(plate) drifted \(drift)° off the shared hue")
            }
        }
    }

    /// Every plate must stand clear of the card it sits on. Deep Forest's
    /// green slot landed ΔE 5.6 from its own green surface and disappeared.
    @Test func noPlateVanishesIntoItsSurface() {
        for theme in TerminalColorTheme.builtInThemes {
            for plate in identity(for: theme) {
                #expect(LabColorMath.distance(theme.appPalette.surfaceHex, plate) >= 11,
                        "\(theme.id) plate \(plate) sinks into its own card")
            }
        }
    }

    /// ...and the tone really is the theme's: a light theme's plates sit high
    /// and saturated, a dark theme's low and muted, from the same four hues.
    @Test func theToneFollowsTheTheme() {
        for theme in TerminalColorTheme.builtInThemes {
            let surface = LabColorMath.lch(of: theme.appPalette.surfaceHex).lightness
            for plate in identity(for: theme).prefix(4) {
                let lightness = LabColorMath.lch(of: plate).lightness
                #expect(abs(lightness - surface) <= 22,
                        "\(theme.id) plate \(plate) is \(lightness) against a surface at \(surface)")
            }
        }
    }


}

@Suite("Pane preset invariants")
struct PanePresetInvariantTests {
    private var panePresets: [TerminalColorTheme] {
        TerminalColorTheme.designStylePresets.filter { $0.id != "neoMilk" }
    }

    /// A shadow is the same material under less light. Scaling sRGB channels
    /// bleeds chroma out with the lightness — it cost Sunlit Chartreuse 12
    /// units and left grey lying on a colored surface — so the elevation
    /// ladder is derived at constant chroma instead.
    @Test func elevationHoldsTheCanvasChroma() {
        for preset in panePresets {
            let palette = preset.appPalette
            let canvas = LabColorMath.lch(of: palette.backgroundHex)
            for (role, hex) in [("well", palette.borderHex),
                                ("shadow", preset.neoStyleColors.shadowDarkHex),
                                ("bloom", preset.neoStyleColors.shadowLightHex)] {
                let role_ = LabColorMath.lch(of: hex)
                // A role can only carry the canvas's chroma where its own
                // lightness has room for it. Near black there is almost none —
                // Midnight Teal's shadow sits at L* 3, where sRGB holds under
                // 8 units of chroma at any hue — so the invariant is measured
                // against what the gamut actually offers there.
                let reachable = min(canvas.chroma,
                                    LabColorMath.maxChroma(lightness: role_.lightness,
                                                           hue: canvas.hue))
                #expect(abs(role_.chroma - reachable) < 3.0,
                        "\(preset.id) \(role) holds \(role_.chroma), could hold \(reachable)")
            }
        }
    }

    /// The distances the shipped presets were tuned to: 16.7 L* down and 9.0
    /// up on a light face, 7.3 and 10.7 on a dark one. A dark canvas has
    /// little room beneath it and plenty above, so the weighting flips rather
    /// than scaling.
    @Test func theShadowPairCastsTheApprovedDistance() {
        for preset in panePresets {
            let palette = preset.appPalette
            let canvas = LabColorMath.lch(of: palette.backgroundHex).lightness
            let down = canvas - LabColorMath.lch(of: preset.neoStyleColors.shadowDarkHex).lightness
            let up = LabColorMath.lch(of: preset.neoStyleColors.shadowLightHex).lightness - canvas
            let expected = palette.isDark ? (down: 7.3, up: 10.7) : (down: 16.7, up: 9.0)
            #expect(abs(down - expected.down) < 1.5, "\(preset.id) casts \(down) down")
            #expect(abs(up - expected.up) < 1.5, "\(preset.id) casts \(up) up")
        }
    }

    /// Chroma is what separates an accent that belongs to its theme from mud
    /// or a scream. A fixed HSL saturation gave yellow-green C* 99 and dark
    /// blue C* 40, and that split is exactly where the accents divided into
    /// the ones that read well and the ones that did not.
    @Test func accentsHoldChromaAndCarryReadableLabels() {
        for preset in panePresets {
            let palette = preset.appPalette
            let chroma = LabColorMath.lch(of: palette.accentHex).chroma
            #expect(chroma > 45, "\(preset.id) accent \(palette.accentHex) is muddy at C* \(chroma)")
            #expect(chroma < 75, "\(preset.id) accent \(palette.accentHex) screams at C* \(chroma)")
            #expect(AgentIdentityTests.contrast(palette.buttonTextOnAccentHex, palette.accentHex) >= 4.5,
                    "\(preset.id) label on accent is unreadable")
        }
    }

    /// Two themes must never wear the same accent. The cool pole is a narrow
    /// band of usable chroma, and Midnight Teal and Deep Harbor both clamped
    /// into it — 21° apart at the source, identical at the output.
    @Test func noTwoPresetsShareAnAccent() {
        let accents = TerminalColorTheme.designStylePresets.map(\.appPalette.accentHex)
        #expect(Set(accents).count == accents.count, "duplicate accent in \(accents)")

        for (first, second) in [("neoMidnightTeal", "neoDeepHarbor")] {
            let a = TerminalColorTheme.designStylePresets.first { $0.id == first }!.appPalette.accentHex
            let b = TerminalColorTheme.designStylePresets.first { $0.id == second }!.appPalette.accentHex
            let separation = abs(((LabColorMath.lch(of: a).hue - LabColorMath.lch(of: b).hue) + 180)
                .truncatingRemainder(dividingBy: 360) - 180)
            #expect(separation > 15, "\(first) and \(second) are \(separation)° apart")
        }
    }
}
