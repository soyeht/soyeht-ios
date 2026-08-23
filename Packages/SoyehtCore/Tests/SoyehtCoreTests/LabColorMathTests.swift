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

    /// Rebuilt here rather than reached through MacTheme, which is AppKit-only.
    private func identity(for theme: TerminalColorTheme) -> [String] {
        let palette = theme.appPalette
        let surface = LabColorMath.lch(of: palette.surfaceHex)
        let anchor = LabColorMath.lch(of: palette.accentHex).hue
        let sunk = surface.lightness - 9
        let lightness = sunk >= 12 ? sunk : max(surface.lightness + 8, 18)
        let hues = [30.0, 80.0, 210.0, 260.0].map { anchor + $0 }
        let chroma = min(28, hues.map {
            LabColorMath.maxChroma(lightness: lightness, hue: $0)
        }.min() ?? 28)
        var fifth = LabColorMath.lch(of: palette.selectionHex)
        let seed = fifth.lightness
        var step = 3.0
        while step <= 60 {
            fifth.lightness = max(6, seed - step)
            if LabColorMath.contrastRatio(palette.textPrimaryHex,
                                          LabColorMath.hex(fifth)) >= 4.5 { break }
            step += 4
        }
        if step > 60 { fifth.lightness = lightness }
        return hues.map {
            LabColorMath.hex(LabColorMath.LCh(lightness: lightness, chroma: chroma, hue: $0))
        } + [LabColorMath.hex(fifth)]
    }

    private func deltaE(_ a: String, _ b: String) -> Double {
        let x = LabColorMath.lch(of: a), y = LabColorMath.lch(of: b)
        let ax = x.chroma * cos(x.hue * .pi / 180), ay = x.chroma * sin(x.hue * .pi / 180)
        let bx = y.chroma * cos(y.hue * .pi / 180), by = y.chroma * sin(y.hue * .pi / 180)
        return ((x.lightness - y.lightness) * (x.lightness - y.lightness)
                + (ax - bx) * (ax - bx) + (ay - by) * (ay - by)).squareRoot()
    }

    /// The set exists to tell panes apart, so any two slots must be visibly
    /// different. This is what eight slots could not deliver: to keep eight
    /// from glaring the chroma had to drop to 10, and at that chroma they were
    /// all the same color.
    @Test func everySlotIsTellableFromEveryOther() {
        for theme in TerminalColorTheme.builtInThemes {
            let set = identity(for: theme)
            for i in set.indices {
                for j in set.indices where j > i {
                    #expect(deltaE(set[i], set[j]) > 10,
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
    /// below the card on every theme with room to sink. A surface too dark for
    /// that has to step up instead, and then only to where color starts to
    /// exist — pure black cannot hold a hue at all, so the floor is what makes
    /// the set possible, not a distance chosen for its own sake.
    @Test func platesSinkRatherThanGlow() {
        for theme in TerminalColorTheme.builtInThemes {
            let surface = LabColorMath.lch(of: theme.appPalette.surfaceHex).lightness
            for plate in identity(for: theme).prefix(4) {
                let lightness = LabColorMath.lch(of: plate).lightness
                if surface - 9 >= 12 {
                    #expect(lightness < surface, "\(theme.id) plate \(plate) outshines its card")
                } else {
                    #expect(lightness <= 26, "\(theme.id) plate \(plate) is a band, not a floor")
                }
            }
        }
    }

    /// The four tetrad slots share a lightness and a chroma — that shared
    /// footing is what makes them read as one palette.
    @Test func theTetradSharesLightnessAndChroma() {
        for theme in TerminalColorTheme.builtInThemes {
            let four = identity(for: theme).prefix(4).map { LabColorMath.lch(of: $0) }
            let lightness = four.map(\.lightness)
            let chroma = four.map(\.chroma)
            #expect((lightness.max()! - lightness.min()!) < 1.5, "\(theme.id) tetrad lightness drifts")
            #expect((chroma.max()! - chroma.min()!) < 2.0, "\(theme.id) tetrad chroma drifts")
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

    /// The pair Caio picked as best: 16.7 L* down and 9.0 up on a light face,
    /// 7.3 and 10.7 on a dark one. A dark canvas has little room beneath it
    /// and plenty above, so the weighting flips rather than scaling.
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
    /// or a scream — a fixed HSL saturation gave yellow-green C* 99 and dark
    /// blue C* 40, which was exactly the split between the two Caio approved
    /// and the six he rejected.
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
