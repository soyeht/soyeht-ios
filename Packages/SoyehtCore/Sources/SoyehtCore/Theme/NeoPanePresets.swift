import Foundation

/// Pane-color neo presets.
///
/// Each one is built from a single authored color — the pane's dominant surface,
/// the color the user actually stares at — with every other role derived from
/// it using the invariants measured on the reference `neoMilk` preset (and on
/// the retired Cream and Midnight presets it shipped beside):
///
/// - elevation is a lightness step measured in CIE L* and taken at CONSTANT
///   CHROMA. A shadow is the same material under less light, so its chroma has
///   to survive the lightness change; deriving it by scaling sRGB channels
///   bleeds chroma away with the lightness, which cost Sunlit Chartreuse 12
///   units and left a grey smudge lying on a colored surface. The pair casts
///   16.7 L* down and 9.0 up from the canvas on a light face, 7.3 down and
///   10.7 up on a dark one — the weighting flips because a dark canvas has
///   little room beneath it and plenty above;
/// - text and accent are CONTRAST targets, not fixed lightnesses — a mid-tone
///   face like Misty Blue drops a fixed-lightness ink to 3:1, so inks are solved
///   to ~7.4:1 (light) and ≥8:1 (dark), matching the reference presets;
/// - ANSI keeps its hues but each slot is pushed until it clears 3:1 against the
///   face, since the stock ramps assume a near-white or near-black screen;
/// - the accent holds CHROMA at C* ~65, which is what separates an accent that
///   belongs to its theme from one that reads as mud or as a scream. A fixed
///   HSL saturation is not chroma: the same value sent yellow-green to C* 99
///   and dark blue to C* 40. Its hue turns toward the nearer of two poles,
///   warm 40° or cool 290°, because sRGB's gamut is anisotropic and those are
///   the only regions holding deep chroma — at Lab hue 255 nothing above C* 48
///   exists at any lightness. Lightness then bends into whatever band the hue
///   can carry. Checked against the preset nobody has faulted: the rule
///   reproduces neoMilk's authored #5B7CFA as #5F84F6.
///
/// Face and terminal screen are the same color (the `neoMilk` model), so a pane
/// reads as one surface rather than a frame around a differently-colored screen.
public extension TerminalColorTheme {
    /// Builds a preset whose chrome and terminal screen share one surface color.
    /// - Parameter screen: the terminal background, when it must differ from
    ///   the chrome. Only a face too near black to carve a recess into needs
    ///   this: the authored color stays on the screen, which is the area the
    ///   user actually reads, and the chrome lifts to where the neumorphic
    ///   roles have room to exist.
    private static func neoPanePreset(
        id: String,
        displayName: String,
        surface: String,
        screen: String? = nil,
        canvas: String,
        hover: String,
        well: String,
        ink: String,
        inkSecondary: String,
        inkMuted: String,
        accent: String,
        buttonTextOnAccent: String,
        shadowDark: String,
        shadowLight: String,
        selection: String,
        ansi: [String]
    ) -> TerminalColorTheme {
        TerminalColorTheme(
            id: id,
            displayName: displayName,
            backgroundHex: screen ?? surface,
            foregroundHex: ink,
            cursorHex: accent,
            selectionBackgroundHex: selection,
            ansiHex: ansi,
            source: .builtIn,
            extraHexColors: [
                "app.background": canvas,
                "app.surface": surface,
                "app.hover": hover,
                "app.border": well,
                "app.textPrimary": ink,
                "app.textSecondary": inkSecondary,
                "app.textMuted": inkMuted,
                "app.accent": accent,
                "app.buttonTextOnAccent": buttonTextOnAccent,
                "neo.surface": surface,
                "neo.well": well,
                "neo.shadowDark": shadowDark,
                "neo.shadowLight": shadowLight,
                "neo.accentShadow": accent,
            ]
        )
    }

    /// Sunrise Gold — light pane surface `#EDB964`.
    static var neoSunriseGold: TerminalColorTheme {
        neoPanePreset(
            id: "neoSunriseGold",
            displayName: "Neo · Sunrise Gold",
            surface: "#EDB964",
            canvas: "#E4B15C",
            hover: "#DEAB57",
            well: "#D8A652",
            ink: "#362E22",
            inkSecondary: "#645948",
            inkMuted: "#84755B",
            accent: "#A84500",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#B38531",
            shadowLight: "#FFCA73",
            selection: "#DE9F4E",
            ansi: [
                "#332B1F", "#C72D45", "#247859", "#876422",
                "#2768C7", "#864DC7", "#247484", "#84755B",
                "#645948", "#D01A3B", "#29775B", "#906112",
                "#0D65DB", "#793CFF", "#257481", "#413625",
            ]
        )
    }

    /// Deep Vine — dark pane surface `#3B3D26`.
    static var neoDeepVine: TerminalColorTheme {
        neoPanePreset(
            id: "neoDeepVine",
            displayName: "Neo · Deep Vine",
            surface: "#3B3D26",
            canvas: "#32341E",
            hover: "#464831",
            well: "#242711",
            ink: "#F1F2E9",
            inkSecondary: "#BFC0AE",
            inkMuted: "#A1A38C",
            accent: "#F5C64C",
            buttonTextOnAccent: "#2C2511",
            shadowDark: "#22240F",
            shadowLight: "#4A4C35",
            selection: "#736631",
            ansi: [
                "#1D1E12", "#EF4747", "#00D9A3", "#F59E0B",
                "#7573FF", "#EA00E9", "#00A5B2", "#BFC0AE",
                "#A1A38C", "#EF4747", "#00D9A3", "#FFAA00",
                "#7673FF", "#EA00E9", "#00E5E5", "#F1F2E9",
            ]
        )
    }

    /// Sunlit Chartreuse — light pane surface `#DCD870`.
    static var neoSunlitChartreuse: TerminalColorTheme {
        neoPanePreset(
            id: "neoSunlitChartreuse",
            displayName: "Neo · Sunlit Chartreuse",
            surface: "#DCD870",
            canvas: "#D2CE67",
            hover: "#CDCA63",
            well: "#C6C35C",
            ink: "#3E3D28",
            inkSecondary: "#6A684C",
            inkMuted: "#88865E",
            accent: "#B55C03",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#A2A13C",
            shadowLight: "#ECE77F",
            selection: "#D3BD58",
            ansi: [
                "#33321F", "#D44158", "#288664", "#977026",
                "#3275D7", "#915ECC", "#298192", "#88865E",
                "#6A684C", "#E4274A", "#2E8566", "#A06D14",
                "#1271F1", "#854DFF", "#298290", "#414025",
            ]
        )
    }

    /// Deep Forest — dark pane surface `#223D22`.
    static var neoDeepForest: TerminalColorTheme {
        neoPanePreset(
            id: "neoDeepForest",
            displayName: "Neo · Deep Forest",
            surface: "#223D22",
            canvas: "#1A341B",
            hover: "#2E482E",
            well: "#0D270E",
            ink: "#E9F2E9",
            inkSecondary: "#AEC0AE",
            inkMuted: "#8CA38C",
            accent: "#B2D353",
            buttonTextOnAccent: "#252C11",
            shadowDark: "#0B240B",
            shadowLight: "#324C32",
            selection: "#4D6A31",
            ansi: [
                "#101C10", "#EF4444", "#00D9A3", "#F59E0B",
                "#6F6DFF", "#E100E0", "#00A5B2", "#AEC0AE",
                "#8CA38C", "#EF4444", "#00D9A3", "#FFAA00",
                "#706CFF", "#E500E5", "#00E5E5", "#E9F2E9",
            ]
        )
    }

    /// Misty Blue — light pane surface `#83A7B4`.
    static var neoMistyBlue: TerminalColorTheme {
        neoPanePreset(
            id: "neoMistyBlue",
            displayName: "Neo · Misty Blue",
            surface: "#83A7B4",
            canvas: "#7B9FAC",
            hover: "#769AA7",
            well: "#7296A2",
            ink: "#0C1012",
            inkSecondary: "#37464C",
            inkMuted: "#4A626B",
            accent: "#004497",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#517480",
            shadowLight: "#93B7C5",
            selection: "#6691AE",
            ansi: [
                "#1F2E33", "#9C2336", "#1C5D46", "#694E1A",
                "#1E519B", "#6B35A8", "#1C5A66", "#4A626B",
                "#37464C", "#A3142F", "#205C47", "#6F4C0E",
                "#0A4FAA", "#4E00FB", "#1D5A64", "#253A41",
            ]
        )
    }

    /// Midnight Teal — dark pane surface `#062635`.
    static var neoMidnightTeal: TerminalColorTheme {
        neoPanePreset(
            id: "neoMidnightTeal",
            displayName: "Neo · Midnight Teal",
            // The one face with no room under it: L* 13.7 leaves 13 units to
            // black, so a recess measured 4 L* and the shadow pair collapsed
            // into it. The chrome lifts to L* 23 where the roles fit; the
            // screen keeps the authored color exactly.
            surface: "#1E3B48",
            screen: "#062635",
            canvas: "#15323F",
            hover: "#2A4654",
            well: "#052531",
            ink: "#E9EFF2",
            inkSecondary: "#AEBAC0",
            inkMuted: "#8C9CA3",
            accent: "#65A1FF",
            buttonTextOnAccent: "#111C2C",
            shadowDark: "#03232F",
            shadowLight: "#2E4A58",
            selection: "#224B72",
            ansi: [
                "#010507", "#EF4444", "#00D9A3", "#F59E0B",
                "#5452FF", "#C100C0", "#00A5B2", "#AEBAC0",
                "#8C9CA3", "#EF4444", "#00D9A3", "#FFAA00",
                "#5651FF", "#E500E5", "#00E5E5", "#E9EFF2",
            ]
        )
    }

    /// Pale Mist — light pane surface `#C0C8CA`.
    static var neoPaleMist: TerminalColorTheme {
        neoPanePreset(
            id: "neoPaleMist",
            displayName: "Neo · Pale Mist",
            surface: "#C0C8CA",
            canvas: "#B8C0C2",
            hover: "#B2BABC",
            well: "#AFB7B9",
            ink: "#25363B",
            inkSecondary: "#4B6268",
            inkMuted: "#5E8089",
            accent: "#0F64D1",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#8C9395",
            shadowLight: "#D1D9DB",
            selection: "#99B2CC",
            ansi: [
                "#1F2F33", "#CE2E48", "#257C5C", "#8B6823",
                "#286CCD", "#8952C8", "#257887", "#5E8089",
                "#4B6268", "#D71B3D", "#2B7B5E", "#946412",
                "#0E68E2", "#7E42FF", "#267885", "#253C41",
            ]
        )
    }

    /// Deep Harbor — dark pane surface `#2B4851`.
    static var neoDeepHarbor: TerminalColorTheme {
        neoPanePreset(
            id: "neoDeepHarbor",
            displayName: "Neo · Deep Harbor",
            surface: "#2B4851",
            canvas: "#223F48",
            hover: "#37545D",
            well: "#13313A",
            ink: "#E9F0F2",
            inkSecondary: "#AEBCC0",
            inkMuted: "#8C9DA3",
            accent: "#65A1FF",
            buttonTextOnAccent: "#111C2C",
            shadowDark: "#112F37",
            shadowLight: "#3B5861",
            selection: "#3C6385",
            ansi: [
                "#192A30", "#F15D5D", "#00D9A3", "#F59E0B",
                "#8280FF", "#FB00FA", "#00A5B2", "#AEBCC0",
                "#8C9DA3", "#F15D5D", "#00D9A3", "#FFAA00",
                "#8380FF", "#FB00FA", "#00E5E5", "#E9F0F2",
            ]
        )
    }

    /// The eight pane-color presets: four light faces, four dark.
    static var neoPanePresets: [TerminalColorTheme] {
        [
            neoSunriseGold,
            neoDeepVine,
            neoSunlitChartreuse,
            neoDeepForest,
            neoMistyBlue,
            neoMidnightTeal,
            neoPaleMist,
            neoDeepHarbor,
        ]
    }
}
