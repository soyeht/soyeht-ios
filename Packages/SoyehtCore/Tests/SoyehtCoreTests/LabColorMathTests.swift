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

@Suite("Header pastels")
struct HeaderPastelTests {
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
    private func pastels(for theme: TerminalColorTheme) -> [String] {
        let palette = theme.appPalette
        let chrome = LabColorMath.lch(of: palette.surfaceHex)
        let anchor = LabColorMath.lch(of: palette.accentHex).hue
        let sunk = chrome.lightness - 5
        let lightness = sunk >= 14 ? sunk : chrome.lightness + 6
        return (0..<8).map { index in
            LabColorMath.hex(LabColorMath.LCh(
                lightness: lightness,
                chroma: 10,
                hue: anchor + Double(index) * 45
            ))
        }
    }

    /// The pill is a plate the name sits on, never a light source. Mixing 76%
    /// into white put it 65 L* above a dark theme's chrome; stepping up by a
    /// measured amount still left a lit bar, because the direction was the
    /// problem. It sinks on every theme that has room to sink.
    @Test func noThemeGetsAPillBrighterThanItsSurface() {
        for preset in TerminalColorTheme.designStylePresets {
            let chrome = LabColorMath.lch(of: preset.appPalette.surfaceHex).lightness
            guard chrome - 5 >= 14 else { continue }   // too dark to sink a plate into
            for pastel in pastels(for: preset) {
                let lightness = LabColorMath.lch(of: pastel).lightness
                #expect(lightness < chrome, "\(preset.id) pill \(pastel) is brighter than its surface")
                #expect(chrome - lightness < 12, "\(preset.id) pill \(pastel) sinks too far")
            }
        }
    }

    /// No shipped preset needs the step-up branch any more — lifting Midnight
    /// Teal's chrome gave it room to sink like the rest. The branch stays for
    /// arbitrary user themes, which can be any color at all, so it is checked
    /// against one rather than left to rot untested.
    @Test func aSurfaceWithNoRoomBelowStepsUpOnlySlightly() {
        let nearBlack = TerminalColorTheme(
            id: "test-near-black",
            displayName: "Near black",
            backgroundHex: "#050708",
            foregroundHex: "#E9EFF2",
            cursorHex: "#41ABDD",
            ansiHex: Array(repeating: "#808080", count: 16),
            source: .custom
        )
        let chrome = LabColorMath.lch(of: nearBlack.appPalette.surfaceHex).lightness
        #expect(chrome - 5 < 14)
        for pastel in pastels(for: nearBlack) {
            let lightness = LabColorMath.lch(of: pastel).lightness
            #expect(lightness > chrome)
            #expect(lightness - chrome < 10, "\(pastel) is a band, not a whisper")
        }
    }

    /// Dark themes carry a near-white ink, so sinking the plate also buys
    /// readability: the agent name renders at 62% alpha over it.
    @Test func darkThemeAgentNamesStayLegible() {
        for preset in TerminalColorTheme.designStylePresets where preset.appPalette.isDark {
            let ink = preset.appPalette.textPrimaryHex
            for pastel in pastels(for: preset) {
                let blended = HexColorMath.mix(pastel, ink, t: 0.62)
                #expect(Self.contrast(blended, pastel) > 4.0,
                        "\(preset.id) agent name on \(pastel) is \(blended)")
            }
        }
    }

    @Test func everyPastelStaysMuted() {
        for preset in TerminalColorTheme.designStylePresets {
            for pastel in pastels(for: preset) {
                #expect(LabColorMath.lch(of: pastel).chroma <= 22.0,
                        "\(preset.id) pastel \(pastel) is not pastel")
            }
        }
    }

    @Test func theEightAreDistinct() {
        for preset in TerminalColorTheme.designStylePresets {
            #expect(Set(pastels(for: preset)).count == 8, "\(preset.id) repeats a pastel")
        }
    }

    /// A scalar sum ignores order, so anagrams and most same-length names
    /// shared a slot. That is what made the assignment look arbitrary.
    @Test func hashSeparatesNamesAScalarSumCollided() {
        func sum(_ s: String) -> Int { s.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } }
        func fnv(_ s: String) -> Int {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 0x1000_0000_01b3 }
            return Int(hash % 8)
        }
        #expect(sum("delia") % 8 == sum("alied") % 8, "premise changed")
        #expect(fnv("delia") != fnv("alied"))
    }
}

@Suite("Theme tone classification")
struct ThemeToneTests {
    /// The mid-tone trap: relative luminance is linear, so its 0.5 mark sits
    /// near L* 76 and called these light faces dark. `preferredColorScheme`
    /// reads this, so a golden theme was asking the system for dark controls.
    @Test func midToneLightFacesAreNotDark() {
        for id in ["neoSunriseGold", "neoSunlitChartreuse", "neoMistyBlue", "neoPaleMist"] {
            let preset = TerminalColorTheme.designStylePresets.first { $0.id == id }
            let palette = try! #require(preset).appPalette
            #expect(!palette.isDark, "\(id) classified dark")
            #expect(LabColorMath.lch(of: palette.backgroundHex).lightness > 50)
        }
    }

    @Test func darkFacesStayDark() {
        for id in ["neoDeepVine", "neoDeepForest", "neoMidnightTeal", "neoDeepHarbor"] {
            let preset = TerminalColorTheme.designStylePresets.first { $0.id == id }
            #expect(try! #require(preset).appPalette.isDark, "\(id) classified light")
        }
    }

    /// Nothing that shipped before may flip tone on this change.
    @Test func existingThemesKeepTheirTone() {
        for theme in ColorTheme.allCases.map(\.terminalTheme) {
            #expect(theme.appPalette.isDark, "\(theme.id) was dark before")
        }
        #expect(!TerminalColorTheme.neoMilk.appPalette.isDark)
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
            #expect(HeaderPastelTests.contrast(palette.buttonTextOnAccentHex, palette.accentHex) >= 4.5,
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
