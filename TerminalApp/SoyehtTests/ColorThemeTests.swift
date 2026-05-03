import Testing
import SoyehtCore
import SwiftUI
import Foundation
@testable import Soyeht

@Suite(.serialized) struct ColorThemeTests {
    private let defaults = UserDefaults.standard
    private let themeKey = "soyeht.terminal.colorTheme"

    init() {
        defaults.removeObject(forKey: themeKey)
    }

    // MARK: - ColorTheme Model

    @Test("Active defaults to soyehtDark when no preference set")
    func activeDefaultsToSoyehtDark() {
        defaults.removeObject(forKey: themeKey)
        #expect(TerminalColorTheme.active.id == ColorTheme.soyehtDark.rawValue)
    }

    @Test("Persistence round trip works")
    func persistenceRoundTrip() {
        TerminalThemeStore.shared.setActiveTheme(id: "dracula")
        #expect(TerminalColorTheme.active.id == ColorTheme.dracula.rawValue)
        defaults.removeObject(forKey: themeKey)
    }

    @Test("Invalid rawValue falls back to soyehtDark")
    func invalidRawValueFallback() {
        defaults.set("nonexistent", forKey: themeKey)
        #expect(TerminalColorTheme.active.id == ColorTheme.soyehtDark.rawValue)
        defaults.removeObject(forKey: themeKey)
    }

    @Test("Each theme has exactly 16 ANSI hex colors")
    func ansiHexCountIs16() {
        for theme in TerminalColorTheme.builtInThemes {
            #expect(theme.ansiHex.count == 16, "Theme \(theme.id) should have 16 ANSI colors")
        }
    }

    @Test("Palette and swiftUIPalette derive same count from ansiHex")
    func paletteAndSwiftUIPaletteSameCount() {
        for theme in TerminalColorTheme.builtInThemes {
            #expect(theme.palette.count == 16)
            #expect(theme.swiftUIPalette.count == 16)
        }
    }

    @Test("Preview swatches returns exactly 4 colors")
    func previewSwatchesCount() {
        for theme in TerminalColorTheme.builtInThemes {
            #expect(theme.previewSwatches.count == 4)
        }
    }

    @Test("All themes have non-empty background, foreground, cursor hex")
    func themeHexesNotEmpty() {
        for theme in TerminalColorTheme.builtInThemes {
            #expect(!theme.backgroundHex.isEmpty)
            #expect(!theme.foregroundHex.isEmpty)
            #expect(!theme.cursorHex.isEmpty)
        }
    }

    @Test("App palette preserves terminal colors and derives readable app tokens")
    func appPaletteUsesOnlyTerminalThemeColors() {
        let backgroundHex = "#010203"
        let foregroundHex = "#F0F1F2"
        let cursorHex = "#ABCDEF"
        let cursorTextHex = "#102030"
        let selectionBackgroundHex = "#203040"
        let selectionForegroundHex = "#304050"
        let linkHex = "#506070"
        let ansi = [
            "#000000", "#111111", "#222222", "#333333",
            "#444444", "#555555", "#666666", "#777777",
            "#888888", "#999999", "#AAAAAA", "#BBBBBB",
            "#CCCCCC", "#DDDDDD", "#EEEEEE", "#FFFFFF",
        ]
        let theme = TerminalColorTheme(
            id: "mapping-test",
            displayName: "Mapping Test",
            backgroundHex: backgroundHex,
            foregroundHex: foregroundHex,
            cursorHex: cursorHex,
            cursorTextHex: cursorTextHex,
            selectionBackgroundHex: selectionBackgroundHex,
            selectionForegroundHex: selectionForegroundHex,
            linkHex: linkHex,
            ansiHex: ansi,
            source: .custom
        )

        let palette = theme.appPalette

        #expect(palette.backgroundHex == backgroundHex)
        #expect(palette.surfaceHex == backgroundHex)
        #expect(palette.surfaceRaisedHex == backgroundHex)
        #expect(palette.cardHex == backgroundHex)
        #expect(palette.borderHex == ansi[8])
        #expect(palette.hoverHex == backgroundHex)
        #expect(palette.textPrimaryHex == foregroundHex)
        #expect(palette.textSecondaryHex == ansi[7])
        #expect(palette.textMutedHex == ansi[8])
        #expect(palette.readableTextOnBackgroundHex == foregroundHex)
        #expect(palette.accentHex == cursorHex)
        #expect(palette.selectionHex == selectionBackgroundHex)
        #expect(palette.selectionTextHex == selectionForegroundHex)
        #expect(palette.readableTextOnSelectionHex == foregroundHex)
        #expect(palette.cursorTextHex == cursorTextHex)
        #expect(palette.dangerHex == ansi[1])
        #expect(palette.successHex == ansi[2])
        #expect(palette.warningHex == ansi[3])
        #expect(palette.linkHex == linkHex)
        #expect(palette.alternateHex == ansi[5])
        #expect(palette.infoHex == ansi[6])
        #expect(palette.dangerStrongHex == ansi[9])
        #expect(palette.successStrongHex == ansi[10])
        #expect(palette.warningStrongHex == ansi[11])
        #expect(palette.linkStrongHex == ansi[12])
        #expect(palette.alternateStrongHex == ansi[13])
        #expect(palette.infoStrongHex == ansi[14])
        #expect(palette.buttonTextOnAccentHex == cursorTextHex)

        let terminalColors = Set([
            theme.backgroundHex,
            theme.foregroundHex,
            theme.cursorHex,
            cursorTextHex,
            selectionBackgroundHex,
            selectionForegroundHex,
            linkHex,
        ] + ansi)
        #expect(Set(palette.allHexValues).isSubset(of: terminalColors))
    }

    @Test("Readable app tokens choose from the theme instead of inventing colors")
    func readableAppTokensUseOnlyThemeColors() {
        let ansi = [
            "#000000", "#101010", "#202020", "#303030",
            "#404040", "#505050", "#606060", "#777777",
            "#080808", "#909090", "#A0A0A0", "#B0B0B0",
            "#C0C0C0", "#D0D0D0", "#E0E0E0", "#FFFFFF",
        ]
        let theme = TerminalColorTheme(
            id: "readability-test",
            displayName: "Readability Test",
            backgroundHex: "#000000",
            foregroundHex: "#FFFFFF",
            cursorHex: "#00FF00",
            cursorTextHex: "#00EE00",
            selectionBackgroundHex: "#00FF00",
            selectionForegroundHex: "#00EE00",
            ansiHex: ansi,
            source: .custom
        )

        let palette = theme.appPalette

        #expect(palette.selectionTextHex == "#00EE00")
        #expect(palette.readableTextOnSelectionHex == "#000000")
        #expect(palette.readableSecondaryTextOnBackgroundHex == "#777777")

        let terminalColors = Set([
            theme.backgroundHex,
            theme.foregroundHex,
            theme.cursorHex,
            theme.cursorTextHex!,
            theme.selectionBackgroundHex!,
            theme.selectionForegroundHex!,
        ] + ansi)
        #expect(Set(palette.allHexValues).isSubset(of: terminalColors))
    }

    @Test("Ghostty theme import parses the full terminal palette")
    func ghosttyImportParsesPalette() throws {
        let text = """
        palette = 0=#111111
        palette = 1=#222222
        palette = 2=#333333
        palette = 3=#444444
        palette = 4=#555555
        palette = 5=#666666
        palette = 6=#777777
        palette = 7=#888888
        palette = 8=#999999
        palette = 9=#AAAAAA
        palette = 10=#BBBBBB
        palette = 11=#CCCCCC
        palette = 12=#DDDDDD
        palette = 13=#EEEEEE
        palette = 14=#ABCDEF
        palette = 15=#FEDCBA
        background = #010203
        foreground = #F0F1F2
        cursor-color = #00FF00
        cursor-text = #102030
        selection-background = #203040
        selection-foreground = #304050
        bold-color = #405060
        link-color = #506070
        split-divider-color = #607080
        """

        let theme = try TerminalThemeImporter.importGhostty(
            text: text,
            filename: "Example.theme",
            sourceURL: nil
        )

        #expect(theme.displayName == "Example")
        #expect(theme.backgroundHex == "#010203")
        #expect(theme.foregroundHex == "#F0F1F2")
        #expect(theme.cursorHex == "#00FF00")
        #expect(theme.cursorTextHex == "#102030")
        #expect(theme.selectionBackgroundHex == "#203040")
        #expect(theme.selectionForegroundHex == "#304050")
        #expect(theme.boldHex == "#405060")
        #expect(theme.linkHex == "#506070")
        #expect(theme.extraHexColors["split-divider-color"] == "#607080")
        #expect(theme.ansiHex.count == 16)
        #expect(theme.ansiHex[14] == "#ABCDEF")
    }

    @Test("iTerm2 theme import preserves extended terminal colors")
    func iterm2ImportPreservesExtendedColors() throws {
        var plist: [String: Any] = [
            "Background Color": plistColor(0x010203),
            "Foreground Color": plistColor(0xF0F1F2),
            "Cursor Color": plistColor(0x00FF00),
            "Cursor Text Color": plistColor(0x102030),
            "Selection Color": plistColor(0x203040),
            "Selected Text Color": plistColor(0x304050),
            "Bold Color": plistColor(0x405060),
            "Link Color": plistColor(0x506070),
            "Badge Color": plistColor(0x607080),
        ]
        for index in 0..<16 {
            plist["Ansi \(index) Color"] = plistColor(index * 0x10101)
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let theme = try TerminalThemeImporter.importItermColors(
            data: data,
            filename: "Example.itermcolors",
            sourceURL: nil
        )

        #expect(theme.displayName == "Example")
        #expect(theme.backgroundHex == "#010203")
        #expect(theme.foregroundHex == "#F0F1F2")
        #expect(theme.cursorHex == "#00FF00")
        #expect(theme.cursorTextHex == "#102030")
        #expect(theme.selectionBackgroundHex == "#203040")
        #expect(theme.selectionForegroundHex == "#304050")
        #expect(theme.boldHex == "#405060")
        #expect(theme.linkHex == "#506070")
        #expect(theme.extraHexColors["badge-color"] == "#607080")
        #expect(theme.ansiHex.count == 16)
        #expect(theme.ansiHex[15] == "#0F0F0F")
    }

    @Test("Bluloco Light iTerm2 import preserves picker-readable colors")
    func blulocoLightImportPreservesPickerReadableColors() throws {
        var plist: [String: Any] = [
            "Background Color": plistColor(0xF9F9F9),
            "Foreground Color": plistColor(0x373A41),
            "Cursor Color": plistColor(0xF32759),
            "Cursor Text Color": plistColor(0xFFFFFF),
            "Selection Color": plistColor(0xDAF0FF),
            "Selected Text Color": plistColor(0x373A41),
            "Bold Color": plistColor(0x383A42),
            "Link Color": plistColor(0x287BDE),
            "Badge Color": plistColor(0xFF2600),
            "Cursor Guide Color": plistColor(0xB3ECFF),
        ]
        let ansi = [
            0x373A41, 0xD52753, 0x23974A, 0xDF631C,
            0x275FE4, 0x823FF1, 0x27618D, 0xBABBC2,
            0x676A77, 0xFF6480, 0x3CBC66, 0xC5A332,
            0x0099E1, 0xCE33C0, 0x6D93BB, 0xD3D3D3,
        ]
        for (index, color) in ansi.enumerated() {
            plist["Ansi \(index) Color"] = plistColor(color)
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let theme = try TerminalThemeImporter.importItermColors(
            data: data,
            filename: "Bluloco Light.itermcolors",
            sourceURL: "https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/schemes/Bluloco%20Light.itermcolors"
        )
        let palette = theme.appPalette

        #expect(theme.id == "bluloco-light")
        #expect(theme.displayName == "Bluloco Light")
        #expect(theme.backgroundHex == "#F9F9F9")
        #expect(theme.foregroundHex == "#373A41")
        #expect(theme.cursorHex == "#F32759")
        #expect(theme.cursorTextHex == "#FFFFFF")
        #expect(theme.selectionBackgroundHex == "#DAF0FF")
        #expect(theme.selectionForegroundHex == "#373A41")
        #expect(theme.boldHex == "#383A42")
        #expect(theme.linkHex == "#287BDE")
        #expect(theme.extraHexColors["badge-color"] == "#FF2600")
        #expect(theme.extraHexColors["cursor-guide-color"] == "#B3ECFF")
        #expect(theme.ansiHex.count == 16)
        #expect(theme.ansiHex[8] == "#676A77")
        #expect(theme.ansiHex[15] == "#D3D3D3")
        #expect(palette.readableTextOnBackgroundHex == "#373A41")
        #expect(palette.readableSecondaryTextOnBackgroundHex == "#373A41")
        #expect(palette.selectionTextHex == "#373A41")
        #expect(palette.readableTextOnSelectionHex == "#373A41")
        #expect(palette.buttonTextOnAccentHex == "#FFFFFF")

        let terminalColors = Set([
            theme.backgroundHex,
            theme.foregroundHex,
            theme.cursorHex,
            theme.cursorTextHex!,
            theme.selectionBackgroundHex!,
            theme.selectionForegroundHex!,
            theme.boldHex!,
            theme.linkHex!,
        ] + theme.ansiHex + theme.extraHexColors.values)
        #expect(Set(palette.allHexValues).isSubset(of: terminalColors))
    }

    private func plistColor(_ rgb: Int) -> [String: Any] {
        [
            "Red Component": Double((rgb >> 16) & 0xFF) / 255.0,
            "Green Component": Double((rgb >> 8) & 0xFF) / 255.0,
            "Blue Component": Double(rgb & 0xFF) / 255.0,
        ]
    }

    @Test("Imported custom themes can be saved and resolved by the store")
    func importedThemeStoreRoundTrip() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoyehtThemeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = TerminalThemeStore(themesDirectory: temp)
        let imported = TerminalColorTheme(
            id: "my-theme",
            displayName: "My Theme",
            backgroundHex: "#000000",
            foregroundHex: "#FFFFFF",
            cursorHex: "#10B981",
            cursorTextHex: "#111111",
            selectionBackgroundHex: "#222222",
            selectionForegroundHex: "#333333",
            boldHex: "#444444",
            linkHex: "#555555",
            ansiHex: ColorTheme.dracula.ansiHex,
            source: .imported,
            extraHexColors: ["badge-color": "#666666"]
        )

        let saved = try store.saveImportedTheme(imported)
        TerminalPreferences.shared.colorTheme = saved.id
        #expect(store.activeTheme.id == saved.id)
        #expect(store.activeTheme.displayName == "My Theme")
        #expect(store.activeTheme.cursorTextHex == "#111111")
        #expect(store.activeTheme.selectionBackgroundHex == "#222222")
        #expect(store.activeTheme.selectionForegroundHex == "#333333")
        #expect(store.activeTheme.boldHex == "#444444")
        #expect(store.activeTheme.linkHex == "#555555")
        #expect(store.activeTheme.extraHexColors["badge-color"] == "#666666")
        defaults.removeObject(forKey: themeKey)
    }

    @Test("iTerm2 catalog JSON lists installable theme files")
    func iterm2CatalogJSONListsInstallableThemes() throws {
        let json = """
        [
          {
            "name": "3024 Day.itermcolors",
            "download_url": "https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/schemes/3024%20Day.itermcolors",
            "html_url": "https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/schemes/3024%20Day.itermcolors",
            "type": "file"
          },
          {
            "name": "README.md",
            "download_url": "https://example.com/README.md",
            "html_url": "https://example.com/README.md",
            "type": "file"
          },
          {
            "name": "nested",
            "download_url": null,
            "html_url": "https://example.com/nested",
            "type": "dir"
          }
        ]
        """

        let items = try TerminalThemeCatalogClient.items(
            fromGitHubContentsData: Data(json.utf8),
            catalogID: TerminalThemeCatalog.iTerm2ColorSchemes.id
        )

        #expect(items.count == 1)
        #expect(items[0].displayName == "3024 Day")
        #expect(items[0].filename == "3024 Day.itermcolors")
        #expect(items[0].catalogID == "iterm2-color-schemes")
    }

    // MARK: - ANSIParser Background SGR

    @Test("Background color 42 (green) resets with 49")
    func bgReset49() {
        defaults.removeObject(forKey: themeKey)
        let result = ANSIParser.parse("\u{1b}[42mbg\u{1b}[49mnormal", fontSize: 13)
        let runs = Array(result.runs)
        #expect(runs.count == 2)
        // First run should have a background color
        #expect(runs[0].backgroundColor != nil)
        // Second run should have no background (reset)
        #expect(runs[1].backgroundColor == nil)
    }

    @Test("Combined foreground and background SGR")
    func fgAndBgCombined() {
        defaults.removeObject(forKey: themeKey)
        let result = ANSIParser.parse("\u{1b}[31;44mtext\u{1b}[0m", fontSize: 13)
        let runs = Array(result.runs)
        // The colored run should have both fg and bg set
        #expect(runs[0].foregroundColor != nil)
        #expect(runs[0].backgroundColor != nil)
    }

    @Test("Reset (0) clears both foreground and background")
    func resetClearsBoth() {
        defaults.removeObject(forKey: themeKey)
        let result = ANSIParser.parse("\u{1b}[31;42mcolored\u{1b}[0mplain", fontSize: 13)
        let runs = Array(result.runs)
        #expect(runs.count == 2)
        // After reset, bg should be nil
        #expect(runs[1].backgroundColor == nil)
    }

    @Test("Default foreground comes from active theme")
    func defaultFgFromTheme() {
        TerminalPreferences.shared.colorTheme = "dracula"
        let result = ANSIParser.parse("plain", fontSize: 13)
        let run = result.runs.first!
        // Dracula foreground is #F8F8F2
        let draculaFg = Color(hex: "#F8F8F2")
        #expect(run.foregroundColor == draculaFg)
        defaults.removeObject(forKey: themeKey)
    }

    @Test("Bright background colors 100-107 parse correctly")
    func brightBgColors() {
        defaults.removeObject(forKey: themeKey)
        let result = ANSIParser.parse("\u{1b}[101mbright red bg\u{1b}[0m", fontSize: 13)
        let runs = Array(result.runs)
        #expect(runs[0].backgroundColor != nil)
    }

    @Test("256-color background via 48;5;n")
    func bg256Color() {
        defaults.removeObject(forKey: themeKey)
        let result = ANSIParser.parse("\u{1b}[48;5;196mred bg\u{1b}[0m", fontSize: 13)
        let runs = Array(result.runs)
        #expect(runs[0].backgroundColor != nil)
    }

    @Test("True color background via 48;2;r;g;b")
    func bgTrueColor() {
        defaults.removeObject(forKey: themeKey)
        let result = ANSIParser.parse("\u{1b}[48;2;255;128;0morange bg\u{1b}[0m", fontSize: 13)
        let runs = Array(result.runs)
        #expect(runs[0].backgroundColor != nil)
    }
}
