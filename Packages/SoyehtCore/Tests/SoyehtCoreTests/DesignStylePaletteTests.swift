import Foundation
import Testing
@testable import SoyehtCore

@Suite("HexColorMath")
struct HexColorMathTests {
    @Test func mixEndpointsReturnInputs() {
        #expect(HexColorMath.mix("#102030", "#FFFFFF", t: 0) == "#102030")
        #expect(HexColorMath.mix("#102030", "#FFFFFF", t: 1) == "#FFFFFF")
    }

    @Test func lightenAndDarkenMoveTowardExtremes() {
        #expect(HexColorMath.lighten("#000000", by: 1) == "#FFFFFF")
        #expect(HexColorMath.darken("#FFFFFF", by: 1) == "#000000")
        #expect(HexColorMath.darken("#E0E5EC", by: 0) == "#E0E5EC")
    }

    @Test func withAlphaAppendsChannel() {
        #expect(HexColorMath.withAlpha("#FFFFFF", 1) == "#FFFFFFFF")
        #expect(HexColorMath.withAlpha("#000000", 0) == "#00000000")
    }
}

@Suite("SoyehtAppPalette chrome overrides")
struct AppPaletteChromeOverrideTests {
    /// Themes without reserved `app.*` keys must derive exactly as before —
    /// this is the zero-change guarantee for every existing user theme.
    @Test func themesWithoutOverridesAreUnchanged() {
        let theme = ColorTheme.soyehtDark.terminalTheme
        let palette = theme.appPalette
        #expect(palette.backgroundHex == theme.backgroundHex)
        #expect(palette.surfaceHex == theme.backgroundHex)
        #expect(palette.textPrimaryHex == theme.foregroundHex)
        #expect(palette.accentHex == theme.cursorHex)
    }

    /// Preset themes may pin a chrome palette that diverges from the
    /// terminal screen colors. Milk is a light terminal (reference look);
    /// Midnight exercises the light-chrome-around-dark-terminal divergence.
    @Test func presetOverridesDivergeChromeFromTerminal() {
        let milk = TerminalColorTheme.neoMilk
        let palette = milk.appPalette
        #expect(palette.backgroundHex == "#E0E5EC")
        #expect(palette.surfaceHex == "#E8EDF4")
        #expect(palette.textPrimaryHex == "#3E4A66")
        #expect(palette.accentHex == "#5B7CFA")
        #expect(milk.backgroundHex == "#E8EDF4")
        #expect(!palette.isDark)

        let midnight = TerminalColorTheme.neoMidnight
        #expect(midnight.backgroundHex == "#101216")
        #expect(midnight.appPalette.backgroundHex == "#23262C")
    }

    /// Overridden chrome must still produce readable text — the WCAG search
    /// runs against the overridden background, not the terminal screen.
    @Test func readableTextComputedAgainstOverriddenBackground() {
        for preset in TerminalColorTheme.designStylePresets {
            let palette = preset.appPalette
            let text = palette.readableTextOnBackgroundHex
            #expect(text != palette.backgroundHex, "\(preset.id) readable text collapsed into background")
        }
    }
}

@Suite("NeoStyleColors")
struct NeoStyleColorsTests {
    @Test func presetsUseCuratedSlots() {
        let neo = TerminalColorTheme.neoMilk.neoStyleColors
        #expect(neo.raisedSurfaceHex == "#E8EDF4")
        #expect(neo.wellHex == "#D8DEE8")
        #expect(neo.shadowDarkHex == "#A6B4C8")
        #expect(neo.shadowLightHex == "#FFFFFF")
    }

    /// Any theme without curated slots must still produce a usable neo set
    /// by derivation — every user theme works with the neomorphic style.
    /// On a pure-black background the dark shadow legitimately equals the
    /// background (depth comes from the light shadow), so the invariant is
    /// dark-shadow ≠ raised surface, not dark-shadow ≠ background.
    @Test func derivesFromArbitraryThemes() {
        for theme in ColorTheme.allCases.map(\.terminalTheme) {
            let neo = theme.neoStyleColors
            #expect(neo.raisedSurfaceHex != neo.wellHex, "\(theme.id) surface == well")
            #expect(neo.shadowDarkHex != neo.shadowLightHex, "\(theme.id) shadows identical")
            #expect(neo.shadowDarkHex != neo.raisedSurfaceHex, "\(theme.id) dark shadow invisible against surface")
        }
    }

    @Test func presetsAreValidBuiltInThemes() throws {
        for preset in TerminalColorTheme.designStylePresets {
            #expect(preset.source == .builtIn)
            #expect(preset.ansiHex.count == 16)
            _ = try preset.validated()
        }
        let all = TerminalThemeStore.shared.allThemes()
        #expect(all.contains { $0.id == "neoMilk" })
    }
}
