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

@Suite("Agent identity colours")
struct AgentIdentityTests {
    /// Every built-in theme states its own colours. Nothing derives them, so
    /// nothing can restyle a theme that was already approved — which is what
    /// happened to the five classic themes and to neoMilk while the plates
    /// were computed from hue rules and lightness floors.
    @Test func everyBuiltInThemePinsItsOwnColours() {
        for theme in TerminalColorTheme.builtInThemes {
            #expect(AgentIdentityPalette.pinnedPlates(in: theme) != nil,
                    "\(theme.id) has no colours of its own and would fall back")
        }
    }

    /// A theme keeps however many it states. The classic themes and neoMilk
    /// carry four; the pane presets carry five. Neither count is converted
    /// into the other.
    @Test func aThemeKeepsTheCountItStates() {
        for id in ["soyehtDark", "solarizedDark", "dracula", "monokai", "highContrast", "neoMilk"] {
            let theme = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == id })
            #expect(AgentIdentityPalette.plates(for: theme).count == 4, "\(id)")
        }
        for preset in TerminalColorTheme.designStylePresets where preset.id != "neoMilk" {
            #expect(AgentIdentityPalette.plates(for: preset).count == 5, "\(preset.id)")
        }
    }

    /// The colours the classic themes and neoMilk had before the derivation
    /// existed, transcribed. They must never move again.
    @Test func theOriginalColoursAreExactlyRestored() {
        let original: [String: [String]] = [
            "soyehtDark":    ["#C6EEE1", "#C2F6E9", "#FBD2D2", "#FDE8C4"],
            "solarizedDark": ["#E2E7C2", "#E2E7C2", "#F7CECD", "#EDE3C2"],
            "dracula":       ["#D5FEDF", "#D5FEDF", "#FFD6D6", "#FCFEE3"],
            "monokai":       ["#EAF8CD", "#E2EDCC", "#F1CBD8", "#EDEDCC"],
            "highContrast":  ["#C2FFC2", "#C2FFC2", "#FFC2C2", "#FFFFC2"],
            "neoMilk":       ["#D8E0FE", "#CDE7DD", "#F6D6DB", "#EEE3CD"],
        ]
        for (id, expected) in original {
            let theme = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == id })
            #expect(AgentIdentityPalette.plates(for: theme) == expected, "\(id)")
        }
    }

    /// An imported theme gets the fixed fallback — the same set for every one
    /// of them, read from nothing about the theme.
    @Test func importedThemesGetTheFixedFallback() {
        let imported = TerminalColorTheme(
            id: "imported", displayName: "Imported",
            backgroundHex: "#002B36", foregroundHex: "#839496", cursorHex: "#5B7CFA",
            ansiHex: Array(repeating: "#808080", count: 16), source: .imported)
        #expect(AgentIdentityPalette.pinnedPlates(in: imported) == nil)
        #expect(AgentIdentityPalette.plates(for: imported) == AgentIdentityPalette.fallbackPlates)
    }
}

@Suite("verifica")
struct Verifica { @Test func dump() {
    for t in TerminalColorTheme.builtInThemes {
        print("V|\(t.id)|\(AgentIdentityPalette.plates(for: t).joined(separator: " "))")
    }
} }

@Suite("captura")
struct Captura { @Test func agora() {
    for t in TerminalColorTheme.builtInThemes {
        let n = t.neoStyleColors
        let convexStart = HexColorMath.lighten(n.raisedSurfaceHex, by: 0.35)
        let convexEnd = HexColorMath.darken(n.raisedSurfaceHex, by: 0.08)
        print("CAP|\(t.id)|\(n.raisedSurfaceHex)|\(n.wellHex)|\(n.shadowDarkHex)|\(n.shadowLightHex)|\(n.accentShadowHex)|\(convexStart)|\(convexEnd)")
    }
} }
