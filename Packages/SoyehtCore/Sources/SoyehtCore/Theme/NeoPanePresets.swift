import Foundation

/// Pane-color neo presets.
///
/// Each one is built from a single authored color — the pane's dominant surface,
/// the color the user actually stares at — with every other role derived from
/// it using the invariants measured on the reference `neoMilk` preset (and on
/// the retired Cream and Midnight presets it shipped beside):
///
/// - elevation is a lightness delta from the face: canvas −0.030, hover ∓0.050,
///   well −0.066, dark shadow −0.205 (light) / −0.088 (dark), bloom +0.067;
/// - text and accent are CONTRAST targets, not fixed lightnesses — a mid-tone
///   face like Misty Blue drops a fixed-lightness ink to 3:1, so inks are solved
///   to ~7.4:1 (light) and ≥8:1 (dark), matching the reference presets;
/// - ANSI keeps its hues but each slot is pushed until it clears 3:1 against the
///   face, since the stock ramps assume a near-white or near-black screen.
///
/// Face and terminal screen are the same color (the `neoMilk` model), so a pane
/// reads as one surface rather than a frame around a differently-colored screen.
public extension TerminalColorTheme {
    /// Builds a preset whose chrome and terminal screen share one surface color.
    private static func neoPanePreset(
        id: String,
        displayName: String,
        surface: String,
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
            backgroundHex: surface,
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
            canvas: "#E2B160",
            hover: "#DBAB5D",
            well: "#D6A75A",
            ink: "#362E22",
            inkSecondary: "#645948",
            inkMuted: "#84755B",
            accent: "#B04716",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#A48045",
            shadowLight: "#F1C783",
            selection: "#E0A053",
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
            canvas: "#343621",
            hover: "#41432D",
            well: "#2C2E1D",
            ink: "#F1F2E9",
            inkSecondary: "#BFC0AE",
            inkMuted: "#A1A38C",
            accent: "#D0DD41",
            buttonTextOnAccent: "#2A2C11",
            shadowDark: "#202215",
            shadowLight: "#4B4D38",
            selection: "#686D2E",
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
            canvas: "#D2CE6B",
            hover: "#CBC868",
            well: "#C6C265",
            ink: "#3E3D28",
            inkSecondary: "#6A684C",
            inkMuted: "#88865E",
            accent: "#9A6C13",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#97944D",
            shadowLight: "#E3E08C",
            selection: "#CDC05C",
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
            canvas: "#1E351E",
            hover: "#294329",
            well: "#192E19",
            ink: "#E9F2E9",
            inkSecondary: "#AEC0AE",
            inkMuted: "#8CA38C",
            accent: "#41DD41",
            buttonTextOnAccent: "#112C11",
            shadowDark: "#122112",
            shadowLight: "#344D34",
            selection: "#2B6D2B",
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
            canvas: "#7D9FAB",
            hover: "#789AA6",
            well: "#7595A1",
            ink: "#0C1012",
            inkSecondary: "#37464C",
            inkMuted: "#4A626B",
            accent: "#11528B",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#576F78",
            shadowLight: "#99B6C1",
            selection: "#6A94AB",
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
            surface: "#062635",
            canvas: "#051E2A",
            hover: "#0D2C3B",
            well: "#04161F",
            ink: "#E9EFF2",
            inkSecondary: "#AEBAC0",
            inkMuted: "#8C9CA3",
            accent: "#41ABDD",
            buttonTextOnAccent: "#11242C",
            shadowDark: "#020A0D",
            shadowLight: "#193644",
            selection: "#184E67",
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
            canvas: "#B9C0C2",
            hover: "#B4BBBD",
            well: "#B0B7B9",
            ink: "#25363B",
            inkSecondary: "#4B6268",
            inkMuted: "#5E8089",
            accent: "#1570AD",
            buttonTextOnAccent: "#FFFFFF",
            shadowDark: "#8D9395",
            shadowLight: "#D3D8DA",
            selection: "#9AB5C4",
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
            canvas: "#274049",
            hover: "#324E57",
            well: "#233A41",
            ink: "#E9F0F2",
            inkSecondary: "#AEBCC0",
            inkMuted: "#8C9DA3",
            accent: "#7ACEE8",
            buttonTextOnAccent: "#11262C",
            shadowDark: "#1C2E34",
            shadowLight: "#3E5860",
            selection: "#43707E",
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
