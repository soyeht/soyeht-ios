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
    /// Rebuilt here rather than reached through MacTheme, which is AppKit-only.
    private func pastels(for theme: TerminalColorTheme) -> [String] {
        let palette = theme.appPalette
        let chrome = LabColorMath.lch(of: palette.surfaceHex)
        let anchor = LabColorMath.lch(of: palette.accentHex).hue
        let lightness = palette.isDark
            ? min(92, chrome.lightness + 13)
            : max(30, chrome.lightness - 5)
        return (0..<8).map { index in
            LabColorMath.hex(LabColorMath.LCh(
                lightness: lightness,
                chroma: 20,
                hue: anchor + Double(index) * 45
            ))
        }
    }

    /// The bug this replaced: mixing 76% into white put the pill 65 L* above
    /// a dark theme's chrome — a near-white band across the pane.
    @Test func darkThemesNeverGetAGlaringPill() {
        for preset in TerminalColorTheme.designStylePresets where preset.appPalette.isDark {
            let chrome = LabColorMath.lch(of: preset.appPalette.surfaceHex).lightness
            for pastel in pastels(for: preset) {
                let lightness = LabColorMath.lch(of: pastel).lightness
                #expect(lightness - chrome < 20, "\(preset.id) pill \(pastel) blows out")
                #expect(lightness < 55, "\(preset.id) pill \(pastel) is not a dark-theme pastel")
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
        for id in ["neoMidnight", "neoDeepVine", "neoDeepForest", "neoMidnightTeal", "neoDeepHarbor"] {
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
        #expect(!TerminalColorTheme.neoCream.appPalette.isDark)
        #expect(TerminalColorTheme.neoMidnight.appPalette.isDark)
    }
}
