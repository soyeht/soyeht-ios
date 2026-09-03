import XCTest
import SwiftUI
@testable import SoyehtCore

/// The kit's numbers are the reviewed design's numbers. Pinning them here is
/// what stops a "small tidy" from restyling every neo surface at once.
final class NeoKitTests: XCTestCase {
    func test_theCloudPaletteReadsNeoMilkAndNeverComputes() {
        let theme = TerminalColorTheme.neoMilk
        let neo = theme.neoStyleColors

        XCTAssertEqual(neo.raisedSurfaceHex, "#E8EDF4")
        XCTAssertEqual(neo.wellHex, "#D8DEE8")
        XCTAssertEqual(neo.shadowDarkHex, "#A6B4C8")
        XCTAssertEqual(neo.shadowLightHex, "#FFFFFF")
        XCTAssertEqual(theme.appPalette.backgroundHex, "#E0E5EC")
        XCTAssertEqual(theme.appPalette.accentHex, "#5B7CFA")
        XCTAssertEqual(theme.appPalette.textPrimaryHex, "#3E4A66")
        XCTAssertNil(neo.wellLipHex, "a light face states no lip; its rim already reads as an edge")

        XCTAssertEqual(NeoPalette.cloud, NeoPalette(theme: .neoMilk))
    }

    func test_blurIsHalvedExactlyOnceOnTheWayToARenderRadius() {
        XCTAssertEqual(NeoShadowMath.renderRadius(blur: 8), 4)
        XCTAssertEqual(NeoShadowMath.renderRadius(blur: 18), 9)
        for elevation in NeoElevation.allCases {
            XCTAssertEqual(elevation.renderRadius, elevation.blur / 2)
        }
    }

    func test_theElevationLadderKeepsItsReviewedPairs() {
        XCTAssertEqual([NeoElevation.chip.offset, NeoElevation.chip.blur], [3, 5])
        XCTAssertEqual([NeoElevation.card.offset, NeoElevation.card.blur], [4, 8])
        XCTAssertEqual([NeoElevation.pill.offset, NeoElevation.pill.blur], [6, 10])
        XCTAssertEqual([NeoElevation.panel.offset, NeoElevation.panel.blur], [9, 18])
        XCTAssertEqual([NeoElevation.hero.offset, NeoElevation.hero.blur], [12, 24])
    }

    func test_reachGrowsWithTheLadderSoAMarginCanBeCheckedAgainstIt() {
        let ladder = NeoElevation.allCases.map(\.reach)
        XCTAssertEqual(ladder, ladder.sorted(), "a heavier elevation must never need less room")
        XCTAssertEqual(NeoElevation.card.reach, 12)
        XCTAssertEqual(NeoElevation.panel.reach, 27)
    }

    func test_radiiMatchTheAppKitSpec() {
        XCTAssertEqual(NeoRadius.card, 20)
        XCTAssertEqual(NeoRadius.control, 12)
        XCTAssertEqual(NeoRadius.pill, 999)
    }

    func test_aThemeWithNoNeoKeysFallsBackWithoutReadingItsOwnColours() {
        let plain = TerminalColorTheme(
            id: "plain",
            displayName: "Plain",
            backgroundHex: "#101010",
            foregroundHex: "#FFFFFF",
            cursorHex: "#FF0000",
            selectionBackgroundHex: "#333333",
            ansiHex: TerminalColorTheme.neoMilk.ansiHex,
            source: .builtIn,
            extraHexColors: [:]
        )
        let neo = plain.neoStyleColors
        XCTAssertEqual(neo.raisedSurfaceHex, NeoStyleColors.fallback.surface)
        XCTAssertEqual(neo.wellHex, NeoStyleColors.fallback.well)
    }
}
