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


@Suite("Neumorphic roles")
struct NeoRoleTests {
    /// Every built-in theme states all five neo roles plus the well's pair.
    /// A role a theme leaves out falls back to another theme's value or to a
    /// fixed default, and either way the theme stops controlling its own look.
    @Test func everyBuiltInThemeStatesEveryRole() {
        for theme in TerminalColorTheme.builtInThemes {
            for role in ["neo.surface", "neo.well", "neo.shadowDark",
                         "neo.shadowLight", "neo.wellShadow", "neo.wellRim"] {
                #expect(theme.extraHexColors[role] != nil, "\(theme.id) states no \(role)")
            }
        }
    }

    /// The eight pane faces, transcribed from the reviewed specimen page.
    /// The well carries its OWN pair: identical to the card's on a light
    /// face, deeper and dimmer on a dark one, where reusing the card's pair
    /// leaves the cavity with no visible edge.
    @Test func thePaneFacesCarryTheReviewedWell() {
        let reviewed: [String: (shadow: String, rim: String, lip: String?)] = [
            "neoSunriseGold":      ("#B38531", "#FFCA73", nil),
            "neoDeepVine":         ("#131400", "#3F412A", "#060700"),
            "neoSunlitChartreuse": ("#A2A13C", "#ECE77F", nil),
            "neoDeepForest":       ("#001200", "#264126", "#000100"),
            "neoMistyBlue":        ("#517480", "#93B7C5", nil),
            "neoMidnightTeal":     ("#000104", "#0B2A39", "#000104"),
            "neoPaleMist":         ("#8C9395", "#D1D9DB", nil),
            "neoDeepHarbor":       ("#001E26", "#304D56", "#00151B"),
        ]
        for (id, expected) in reviewed {
            let theme = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == id })
            let neo = theme.neoStyleColors
            #expect(neo.wellShadowHex == expected.shadow, "\(id) well shadow")
            #expect(neo.wellRimHex == expected.rim, "\(id) well rim")
            #expect(neo.wellLipHex == expected.lip, "\(id) well lip")
        }
    }

    /// The lip is the dark faces' alone. A light face's rim already reads as
    /// an edge, and a hard line there would draw itself instead of the recess.
    @Test func onlyTheDarkFacesCarryALip() {
        for theme in TerminalColorTheme.builtInThemes where theme.neoStyleColors.wellLipHex != nil {
            #expect(LabColorMath.lch(of: theme.neoStyleColors.raisedSurfaceHex).lightness < 50,
                    "\(theme.id) is a light face and states a lip")
        }
    }

    /// A theme carrying no well roles takes the card's pair — a value it
    /// already states, never one computed from it.
    @Test func aThemeWithoutWellRolesTakesItsCardPair() {
        let imported = TerminalColorTheme(
            id: "imported", displayName: "Imported",
            backgroundHex: "#002B36", foregroundHex: "#839496", cursorHex: "#5B7CFA",
            ansiHex: Array(repeating: "#808080", count: 16), source: .imported)
        let neo = imported.neoStyleColors
        #expect(neo.wellShadowHex == neo.shadowDarkHex)
        #expect(neo.wellRimHex == neo.shadowLightHex)
        #expect(neo.wellLipHex == nil)
    }
}

@Suite("Terminal greyscale")
struct TerminalGreyscaleTests {
    /// Bright-black, white, bright-white: each one further from the screen
    /// than the last, so a program stepping up the greyscale gets a
    /// direction. Slot 0 is left out — black is the most visible tone a light
    /// face owns and the least visible a dark one owns, which is correct on
    /// both and belongs to no single ordering.
    ///
    /// The four light faces used to double back at the top: bright-white came
    /// out DARKER than white — 6.6:1 against 2.5:1 on Sunrise Gold — so bold
    /// white text, which prompts and TUIs lean on, rendered darker than plain
    /// white. Slots 7 and 8 were also swapped against the dark faces, which
    /// left "white" as the least visible tone the theme owns.
    @Test func theGreyscaleRunsOneWayOnEveryFace() {
        for preset in TerminalColorTheme.designStylePresets where preset.id != "neoMilk" {
            let ansi = preset.ansiHex
            let ramp = [ansi[8], ansi[7], ansi[15]].map {
                LabColorMath.distance(preset.backgroundHex, $0)
            }
            #expect(ramp == ramp.sorted(), "\(preset.id) doubles back: \(ramp)")
        }
    }

    /// Slots 7 and 15 are the ones ordinary output lands on. Neither may be
    /// the washed tone.
    @Test func whiteAndBrightWhiteStayReadable() {
        for preset in TerminalColorTheme.designStylePresets where preset.id != "neoMilk" {
            for slot in [7, 15] {
                #expect(LabColorMath.contrastRatio(preset.ansiHex[slot], preset.backgroundHex) >= 3,
                        "\(preset.id) ansi[\(slot)]")
            }
        }
    }
}
