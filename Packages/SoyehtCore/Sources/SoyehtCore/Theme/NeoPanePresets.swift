import Foundation

/// The eight pane colour presets.
///
/// Every value here is authored and reviewed. Read them as data: nothing in
/// this file is regenerated, and no rule stated anywhere licenses changing one
/// of these hexes. If a colour needs to change, it changes because someone
/// decided it should.
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
        wellShadow: String,
        wellRim: String,
        wellLip: String? = nil,
        selection: String,
        identity: [String],
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
                "neo.wellShadow": wellShadow,
                "neo.wellRim": wellRim,
                "neo.accentShadow": accent,
                // The five agent identity plates, pinned rather than derived.
                // Every other role in this file is a literal already; these
                // were the one exception, recomputed on every read, so a
                // change to a threshold in AgentIdentityPalette silently moved
                // colours that had been reviewed and approved. Derivation is
                // now what a theme falls back to when it has none of its own,
                // which is every imported and user theme.
                "agent.0": identity[0],
                "agent.1": identity[1],
                "agent.2": identity[2],
                "agent.3": identity[3],
                "agent.4": identity[4],
            ].merging(wellLip.map { ["neo.wellLip": $0] } ?? [:]) { current, _ in current }
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
            wellShadow: "#B38531",
            wellRim: "#FFCA73",
            selection: "#DE9F4E",
            identity: [
                "#BE9ECC",
                "#DB96A4",
                "#90B386",
                "#63B7AE",
                "#D59746",
            ],
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
            wellShadow: "#131400",
            wellRim: "#3F412A",
            wellLip: "#060700",
            selection: "#736631",
            identity: [
                "#392840",
                "#47232C",
                "#1A3915",
                "#003531",
                "#6B5F2A",
            ],
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
            wellShadow: "#A2A13C",
            wellRim: "#ECE77F",
            selection: "#D3BD58",
            identity: [
                "#D1AFDE",
                "#EEA8B5",
                "#A1C497",
                "#75C9C0",
                "#CAB550",
            ],
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
            wellShadow: "#001200",
            wellRim: "#264126",
            wellLip: "#000100",
            selection: "#4D6A31",
            identity: [
                "#392840",
                "#47232C",
                "#3A5A33",
                "#003531",
                "#46632A",
            ],
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
            wellShadow: "#517480",
            wellRim: "#93B7C5",
            selection: "#6691AE",
            identity: [
                "#9E7FAB",
                "#B97785",
                "#719368",
                "#41978F",
                "#5E89A6",
            ],
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
            // Chrome and screen are the same color here, as on every other
            // pane preset. Lifting the chrome clear of the screen gave the
            // depth roles more room, but it split the pane into two visibly
            // different tones — and a pane reading as ONE surface is the
            // premise this whole set is built on. The recess it bought was not
            // worth the seam. The cost is paid in chroma instead: at L* 3.7
            // the well and shadow are effectively black rather than tinted
            // teal. The STEP survives — 9.7 L* from face to well, against 9.9
            // to 10.2 on the other dark faces.
            surface: "#062635",
            canvas: "#00202E",
            hover: "#133140",
            well: "#001019",
            ink: "#E9EFF2",
            inkSecondary: "#AEBAC0",
            inkMuted: "#8C9CA3",
            accent: "#7FA7FF",
            buttonTextOnAccent: "#001F45",
            shadowDark: "#000F18",
            shadowLight: "#1A3746",
            wellShadow: "#000104",
            wellRim: "#0B2A39",
            wellLip: "#000104",
            selection: "#2A4D72",
            identity: [
                "#402D48",
                "#4F2831",
                "#253920",
                "#003C37",
                "#22466A",
            ],
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
            wellShadow: "#8C9395",
            wellRim: "#D1D9DB",
            selection: "#99B2CC",
            identity: [
                "#C3A2D1",
                "#E19BA9",
                "#94B88A",
                "#68BCB3",
                "#91AAC4",
            ],
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
            accent: "#19B2FF",
            buttonTextOnAccent: "#002237",
            shadowDark: "#112F37",
            shadowLight: "#3B5861",
            wellShadow: "#001E26",
            wellRim: "#304D56",
            wellLip: "#00151B",
            selection: "#266885",
            identity: [
                "#3B2942",
                "#49252D",
                "#21351D",
                "#003733",
                "#1C617D",
            ],
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
