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

/// Real schemes people actually import, light and dark, transcribed from the
/// iTerm2 colour-scheme collection. The built-in themes all state their own
/// colours, so they exercise none of the selection path; these are the only
/// input that does, and the defects that shipped were all on light ones.
enum ImportedThemeFixtures {
    static func make(
        _ id: String, bg: String, fg: String, cursor: String,
        selection: String? = nil, ansi: [String]
    ) -> TerminalColorTheme {
        TerminalColorTheme(
            id: id, displayName: id, backgroundHex: bg, foregroundHex: fg,
            cursorHex: cursor, selectionBackgroundHex: selection,
            ansiHex: ansi, source: .imported)
    }

    static let all: [TerminalColorTheme] = [
        // PaperColor Light
        make("paperColorLight", bg: "#EEEEEE", fg: "#444444", cursor: "#5F8787",
             selection: "#B2CCD6", ansi: [
                "#EEEEEE", "#AF0000", "#008700", "#5F8700",
                "#0087AF", "#878787", "#005F87", "#444444",
                "#BCBCBC", "#D70000", "#D70087", "#8700AF",
                "#D75F00", "#D75F00", "#005FAF", "#005F87"]),
        // Solarized Light
        make("solarizedLight", bg: "#FDF6E3", fg: "#657B83", cursor: "#657B83",
             selection: "#EEE8D5", ansi: [
                "#073642", "#DC322F", "#859900", "#B58900",
                "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                "#002B36", "#CB4B16", "#586E75", "#657B83",
                "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
        // Gruvbox Light
        make("gruvboxLight", bg: "#FBF1C7", fg: "#3C3836", cursor: "#3C3836",
             selection: "#D5C4A1", ansi: [
                "#FBF1C7", "#CC241D", "#98971A", "#D79921",
                "#458588", "#B16286", "#689D6A", "#7C6F64",
                "#928374", "#9D0006", "#79740E", "#B57614",
                "#076678", "#8F3F71", "#427B58", "#3C3836"]),
        // Nord
        make("nord", bg: "#2E3440", fg: "#D8DEE9", cursor: "#D8DEE9",
             selection: "#434C5E", ansi: [
                "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        // One Half Dark
        make("oneHalfDark", bg: "#282C34", fg: "#DCDFE4", cursor: "#A3B3CC",
             selection: "#474E5D", ansi: [
                "#282C34", "#E06C75", "#98C379", "#E5C07B",
                "#61AFEF", "#C678DD", "#56B6C2", "#DCDFE4",
                "#5A6374", "#E06C75", "#98C379", "#E5C07B",
                "#61AFEF", "#C678DD", "#56B6C2", "#DCDFE4"]),
    ]
}

@Suite("The reviewed pane faces")
struct ReviewedFaceTests {
    /// Every colour the reviewed specimen page shows, for all eight faces,
    /// transcribed off the page and asserted against what the app resolves.
    ///
    /// This is the whole point of the freeze, so it is a full snapshot rather
    /// than a sample: any hex that moves for any reason — a new derivation, an
    /// edit to a preset, a role quietly falling back to another theme's value
    /// — fails here by name. The eight faces were reviewed and approved; code
    /// does not get to restate them.
    struct Face {
        let screen, canvas, surface, well, shadowDark, shadowLight: String
        let wellShadow, wellRim: String
        let wellLip: String?
        let ink, ink2, ink3, accent, selection: String
        let plates: [String]
        let ansi: [String]
    }

    static let reviewed: [String: Face] = [
        "neoSunriseGold": Face(
            screen: "#EDB964", canvas: "#E4B15C", surface: "#EDB964",
            well: "#D8A652", shadowDark: "#B38531", shadowLight: "#FFCA73",
            wellShadow: "#B38531", wellRim: "#FFCA73", wellLip: nil,
            ink: "#362E22", ink2: "#645948", ink3: "#84755B",
            accent: "#A84500", selection: "#DE9F4E",
            plates: ["#BE9ECC", "#DB96A4", "#90B386", "#63B7AE", "#D59746"],
            ansi: [
                "#332B1F", "#C72D45", "#247859", "#876422",
                "#2768C7", "#864DC7", "#247484", "#645948",
                "#84755B", "#D01A3B", "#29775B", "#906112",
                "#0D65DB", "#793CFF", "#257481", "#362E22",
            ]),
        "neoDeepVine": Face(
            screen: "#3B3D26", canvas: "#32341E", surface: "#3B3D26",
            well: "#242711", shadowDark: "#22240F", shadowLight: "#4A4C35",
            wellShadow: "#131400", wellRim: "#3F412A", wellLip: "#060700",
            ink: "#F1F2E9", ink2: "#BFC0AE", ink3: "#A1A38C",
            accent: "#F5C64C", selection: "#736631",
            plates: ["#392840", "#47232C", "#1A3915", "#003531", "#6B5F2A"],
            ansi: [
                "#1D1E12", "#EF4747", "#00D9A3", "#F59E0B",
                "#7573FF", "#EA00E9", "#00A5B2", "#BFC0AE",
                "#A1A38C", "#EF4747", "#00D9A3", "#FFAA00",
                "#7673FF", "#EA00E9", "#00E5E5", "#F1F2E9",
            ]),
        "neoSunlitChartreuse": Face(
            screen: "#DCD870", canvas: "#D2CE67", surface: "#DCD870",
            well: "#C6C35C", shadowDark: "#A2A13C", shadowLight: "#ECE77F",
            wellShadow: "#A2A13C", wellRim: "#ECE77F", wellLip: nil,
            ink: "#3E3D28", ink2: "#6A684C", ink3: "#88865E",
            accent: "#B55C03", selection: "#D3BD58",
            plates: ["#D1AFDE", "#EEA8B5", "#A1C497", "#75C9C0", "#CAB550"],
            ansi: [
                "#33321F", "#D44158", "#288664", "#977026",
                "#3275D7", "#915ECC", "#298192", "#6A684C",
                "#88865E", "#E4274A", "#2E8566", "#A06D14",
                "#1271F1", "#854DFF", "#298290", "#3E3D28",
            ]),
        "neoDeepForest": Face(
            screen: "#223D22", canvas: "#1A341B", surface: "#223D22",
            well: "#0D270E", shadowDark: "#0B240B", shadowLight: "#324C32",
            wellShadow: "#001200", wellRim: "#264126", wellLip: "#000100",
            ink: "#E9F2E9", ink2: "#AEC0AE", ink3: "#8CA38C",
            accent: "#B2D353", selection: "#4D6A31",
            plates: ["#392840", "#47232C", "#3A5A33", "#003531", "#46632A"],
            ansi: [
                "#101C10", "#EF4444", "#00D9A3", "#F59E0B",
                "#6F6DFF", "#E100E0", "#00A5B2", "#AEC0AE",
                "#8CA38C", "#EF4444", "#00D9A3", "#FFAA00",
                "#706CFF", "#E500E5", "#00E5E5", "#E9F2E9",
            ]),
        "neoMistyBlue": Face(
            screen: "#83A7B4", canvas: "#7B9FAC", surface: "#83A7B4",
            well: "#7296A2", shadowDark: "#517480", shadowLight: "#93B7C5",
            wellShadow: "#517480", wellRim: "#93B7C5", wellLip: nil,
            ink: "#0C1012", ink2: "#37464C", ink3: "#4A626B",
            accent: "#004497", selection: "#6691AE",
            plates: ["#9E7FAB", "#B97785", "#719368", "#41978F", "#5E89A6"],
            ansi: [
                "#1F2E33", "#9C2336", "#1C5D46", "#694E1A",
                "#1E519B", "#6B35A8", "#1C5A66", "#37464C",
                "#4A626B", "#A3142F", "#205C47", "#6F4C0E",
                "#0A4FAA", "#4E00FB", "#1D5A64", "#0C1012",
            ]),
        "neoMidnightTeal": Face(
            screen: "#062635", canvas: "#00202E", surface: "#062635",
            well: "#001019", shadowDark: "#000F18", shadowLight: "#1A3746",
            wellShadow: "#000104", wellRim: "#0B2A39", wellLip: "#000104",
            ink: "#E9EFF2", ink2: "#AEBAC0", ink3: "#8C9CA3",
            accent: "#7FA7FF", selection: "#2A4D72",
            plates: ["#402D48", "#4F2831", "#253920", "#003C37", "#22466A"],
            ansi: [
                "#010507", "#EF4444", "#00D9A3", "#F59E0B",
                "#5452FF", "#C100C0", "#00A5B2", "#AEBAC0",
                "#8C9CA3", "#EF4444", "#00D9A3", "#FFAA00",
                "#5651FF", "#E500E5", "#00E5E5", "#E9EFF2",
            ]),
        "neoPaleMist": Face(
            screen: "#C0C8CA", canvas: "#B8C0C2", surface: "#C0C8CA",
            well: "#AFB7B9", shadowDark: "#8C9395", shadowLight: "#D1D9DB",
            wellShadow: "#8C9395", wellRim: "#D1D9DB", wellLip: nil,
            ink: "#25363B", ink2: "#4B6268", ink3: "#5E8089",
            accent: "#0F64D1", selection: "#99B2CC",
            plates: ["#C3A2D1", "#E19BA9", "#94B88A", "#68BCB3", "#91AAC4"],
            ansi: [
                "#1F2F33", "#CE2E48", "#257C5C", "#8B6823",
                "#286CCD", "#8952C8", "#257887", "#4B6268",
                "#5E8089", "#D71B3D", "#2B7B5E", "#946412",
                "#0E68E2", "#7E42FF", "#267885", "#25363B",
            ]),
        "neoDeepHarbor": Face(
            screen: "#2B4851", canvas: "#223F48", surface: "#2B4851",
            well: "#13313A", shadowDark: "#112F37", shadowLight: "#3B5861",
            wellShadow: "#001E26", wellRim: "#304D56", wellLip: "#00151B",
            ink: "#E9F0F2", ink2: "#AEBCC0", ink3: "#8C9DA3",
            accent: "#19B2FF", selection: "#266885",
            plates: ["#3B2942", "#49252D", "#21351D", "#003733", "#1C617D"],
            ansi: [
                "#192A30", "#F15D5D", "#00D9A3", "#F59E0B",
                "#8280FF", "#FB00FA", "#00A5B2", "#AEBCC0",
                "#8C9DA3", "#F15D5D", "#00D9A3", "#FFAA00",
                "#8380FF", "#FB00FA", "#00E5E5", "#E9F0F2",
            ]),
    ]

    @Test func everyReviewedColourSurvivesTheCode() {
        for (id, face) in Self.reviewed {
            let theme = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == id })
            let neo = theme.neoStyleColors
            let palette = theme.appPalette
            let checks: [(String, String, String)] = [
                ("screen", theme.backgroundHex, face.screen),
                ("canvas", palette.backgroundHex, face.canvas),
                ("surface", neo.raisedSurfaceHex, face.surface),
                ("well", neo.wellHex, face.well),
                ("shadowDark", neo.shadowDarkHex, face.shadowDark),
                ("shadowLight", neo.shadowLightHex, face.shadowLight),
                ("wellShadow", neo.wellShadowHex, face.wellShadow),
                ("wellRim", neo.wellRimHex, face.wellRim),
                ("accent", palette.accentHex, face.accent),
                ("ink", palette.textPrimaryHex, face.ink),
                ("ink2", palette.textSecondaryHex, face.ink2),
                ("ink3", palette.textMutedHex, face.ink3),
                ("selection", theme.selectionBackgroundHex ?? "", face.selection),
            ]
            for (role, got, want) in checks {
                #expect(got.uppercased() == want.uppercased(), "\(id) \(role): \(got) != \(want)")
            }
            #expect(neo.wellLipHex?.uppercased() == face.wellLip?.uppercased(), "\(id) wellLip")
            #expect(AgentIdentityPalette.plates(for: theme).map { $0.uppercased() }
                    == face.plates.map { $0.uppercased() }, "\(id) plates")
            #expect(theme.ansiHex.map { $0.uppercased() }
                    == face.ansi.map { $0.uppercased() }, "\(id) ansi")
        }
    }

    /// Nothing about these eight can ever be derived, because they leave no
    /// role for a derivation to fill. Stated separately from the snapshot so a
    /// missing role fails as "states no X" rather than as a hex mismatch.
    @Test func theReviewedFacesLeaveNothingToFallBackOn() {
        let required = ["neo.surface", "neo.well", "neo.shadowDark", "neo.shadowLight",
                        "neo.wellShadow", "neo.wellRim", "neo.accentShadow",
                        "agent.0", "agent.1", "agent.2", "agent.3", "agent.4",
                        "app.background", "app.surface", "app.accent",
                        "app.textPrimary", "app.textSecondary", "app.textMuted"]
        for id in Self.reviewed.keys {
            let theme = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == id })
            for role in required {
                #expect(theme.extraHexColors[role] != nil, "\(id) states no \(role)")
            }
        }
    }
}

@Suite("Agent identity colours")
struct AgentIdentityTests {
    /// Every theme the plate-painting style wears states its own plates.
    /// Nothing derives them, so nothing can restyle a theme that was already
    /// approved — which is what happened to neoMilk while the plates were
    /// computed from hue rules and lightness floors.
    @Test func everyWornThemeStatesItsOwnPlates() {
        for theme in TerminalColorTheme.builtInThemes where DesignStyle.neomorphic.canWear(theme) {
            #expect(AgentIdentityPalette.pinnedPlates(in: theme) != nil,
                    "\(theme.id) has no colours of its own")
        }
    }

    /// A theme keeps however many it states. neoMilk carries four; the eight
    /// pane faces carry five. Neither count is converted into the other.
    @Test func aThemeKeepsTheCountItStates() {
        let milk = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == "neoMilk" })
        #expect(AgentIdentityPalette.plates(for: milk).count == 4)
        for preset in TerminalColorTheme.designStylePresets where preset.id != "neoMilk" {
            #expect(AgentIdentityPalette.plates(for: preset).count == 5, "\(preset.id)")
        }
    }

    /// neoMilk's four, exactly as they were before any derivation existed.
    /// This is the theme that got restyled without anyone asking, so it is
    /// the one whose values are written out here by hand.
    @Test func milksOriginalColoursAreExactlyRestored() {
        let milk = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == "neoMilk" })
        #expect(AgentIdentityPalette.plates(for: milk)
                == ["#D8E0FE", "#CDE7DD", "#F6D6DB", "#EEE3CD"])
    }

    /// The five terminal colour themes state no plates at all, and must not:
    /// the style that paints plates does not wear them.
    @Test func theTerminalThemesStateNoPlates() {
        for id in ["soyehtDark", "solarizedDark", "dracula", "monokai", "highContrast"] {
            let theme = try! #require(TerminalColorTheme.builtInThemes.first { $0.id == id })
            #expect(AgentIdentityPalette.pinnedPlates(in: theme) == nil, "\(id)")
            #expect(!DesignStyle.neomorphic.canWear(theme), "\(id)")
        }
    }

    /// The whole gap the derivation used to fill is gone: a theme states its
    /// plates or the style that paints them will not wear it. Both halves are
    /// asserted, because either one alone leaves the hole open.
    @Test func onlyAThemeThatStatesPlatesIsWornByTheStyleThatPaintsThem() {
        for theme in ImportedThemeFixtures.all {
            #expect(AgentIdentityPalette.pinnedPlates(in: theme) == nil, "\(theme.id)")
            #expect(AgentIdentityPalette.plates(for: theme).isEmpty,
                    "\(theme.id) shows plates it never stated")
            #expect(!DesignStyle.neomorphic.canWear(theme),
                    "\(theme.id) states no neo roles yet neomorphic would wear it")
        }
    }

    /// The agent's name is printed on the plate. If it cannot be read there
    /// the plate has failed at the one thing it does. The floor is the one
    /// the reviewed faces themselves hold — 5.10 is the lowest of the eight,
    /// so it is a standard they set rather than one imposed on them.
    @Test func theNameReadsOnEveryPlate() {
        for theme in TerminalColorTheme.builtInThemes where DesignStyle.neomorphic.canWear(theme) {
            let ink = theme.appPalette.textPrimaryHex
            for plate in AgentIdentityPalette.plates(for: theme) {
                let ratio = LabColorMath.contrastRatio(ink, plate)
                #expect(ratio >= 5,
                        "\(theme.id): \(ink) on \(plate) is \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// Two plates a reader cannot tell apart are one plate, and the header
    /// hands them out by hash — a collision is invisible until two agents
    /// land on it. Floor again from the reviewed set: Deep Forest's closest
    /// pair sits at 10.5.
    @Test func everyPlateIsTellableFromEveryOther() {
        for theme in TerminalColorTheme.builtInThemes where DesignStyle.neomorphic.canWear(theme) {
            let plates = AgentIdentityPalette.plates(for: theme)
            for i in plates.indices {
                for j in plates.indices where j > i {
                    let delta = LabColorMath.distance(plates[i], plates[j])
                    #expect(delta >= 10,
                            "\(theme.id): \(plates[i]) and \(plates[j]) are \(String(format: "%.1f", delta)) apart")
                }
            }
        }
    }

    /// A theme the style wears has to have plates to hand out.
    @Test func everyWorntThemeHasPlates() {
        for theme in TerminalColorTheme.builtInThemes where DesignStyle.neomorphic.canWear(theme) {
            #expect(AgentIdentityPalette.plates(for: theme).count >= 4, "\(theme.id)")
        }
    }

    /// Exactly the nine neo themes, by name. A tenth appearing here means a
    /// theme picked up neo roles it was never designed for; one missing means
    /// a theme the user can no longer select in neomorphic.
    @Test func neomorphicWearsTheNineItWasDesignedFor() {
        let worn = Set(TerminalColorTheme.builtInThemes
            .filter { DesignStyle.neomorphic.canWear($0) }.map(\.id))
        #expect(worn == [
            "neoMilk", "neoSunriseGold", "neoDeepVine", "neoSunlitChartreuse",
            "neoDeepForest", "neoMistyBlue", "neoMidnightTeal", "neoPaleMist",
            "neoDeepHarbor",
        ], "worn: \(worn.sorted())")
    }

    /// Classic wears everything, including the five terminal themes and any
    /// import. That is what makes gating neomorphic safe rather than a
    /// feature removal.
    @Test func classicStillWearsEverything() {
        for theme in ImportedThemeFixtures.all + TerminalColorTheme.builtInThemes {
            #expect(DesignStyle.classic.canWear(theme), "\(theme.id)")
        }
    }
}


@Suite("Neumorphic roles")
struct NeoRoleTests {
    /// Every theme neomorphic wears states all five neo roles plus the
    /// well's pair. A role a theme leaves out falls back to a fixed default,
    /// and the theme stops controlling its own look.
    @Test func everyWornThemeStatesEveryRole() {
        for theme in TerminalColorTheme.builtInThemes where DesignStyle.neomorphic.canWear(theme) {
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
