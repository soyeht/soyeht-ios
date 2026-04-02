import Testing
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
        #expect(ColorTheme.active == .soyehtDark)
    }

    @Test("Persistence round trip works")
    func persistenceRoundTrip() {
        TerminalPreferences.shared.colorTheme = "dracula"
        #expect(ColorTheme.active == .dracula)
        defaults.removeObject(forKey: themeKey)
    }

    @Test("Invalid rawValue falls back to soyehtDark")
    func invalidRawValueFallback() {
        defaults.set("nonexistent", forKey: themeKey)
        #expect(ColorTheme.active == .soyehtDark)
        defaults.removeObject(forKey: themeKey)
    }

    @Test("Each theme has exactly 16 ANSI hex colors")
    func ansiHexCountIs16() {
        for theme in ColorTheme.allCases {
            #expect(theme.ansiHex.count == 16, "Theme \(theme.displayName) should have 16 ANSI colors")
        }
    }

    @Test("Palette and swiftUIPalette derive same count from ansiHex")
    func paletteAndSwiftUIPaletteSameCount() {
        for theme in ColorTheme.allCases {
            #expect(theme.palette.count == 16)
            #expect(theme.swiftUIPalette.count == 16)
        }
    }

    @Test("Preview swatches returns exactly 4 colors")
    func previewSwatchesCount() {
        for theme in ColorTheme.allCases {
            #expect(theme.previewSwatches.count == 4)
        }
    }

    @Test("All themes have non-empty background, foreground, cursor hex")
    func themeHexesNotEmpty() {
        for theme in ColorTheme.allCases {
            #expect(!theme.backgroundHex.isEmpty)
            #expect(!theme.foregroundHex.isEmpty)
            #expect(!theme.defaultCursorHex.isEmpty)
        }
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
