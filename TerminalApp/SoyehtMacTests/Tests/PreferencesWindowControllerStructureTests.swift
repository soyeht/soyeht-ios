import XCTest

final class PreferencesWindowControllerStructureTests: XCTestCase {
    func test_themeWindowsStayExtractedFromPreferencesController() throws {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
        let macSources = terminalApp.appendingPathComponent("SoyehtMac")

        let preferences = macSources.appendingPathComponent("PreferencesWindowController.swift")
        let catalog = macSources.appendingPathComponent("ThemeCatalogWindowController.swift")
        let editor = macSources.appendingPathComponent("ThemeEditorWindowController.swift")

        let preferencesText = try String(contentsOf: preferences, encoding: .utf8)
        let catalogText = try String(contentsOf: catalog, encoding: .utf8)
        let editorText = try String(contentsOf: editor, encoding: .utf8)

        XCTAssertLessThanOrEqual(
            preferencesText.split(whereSeparator: \.isNewline).count,
            520,
            "Keep theme catalog/editor UI out of PreferencesWindowController.swift."
        )
        XCTAssertFalse(preferencesText.contains("final class ThemeCatalogWindowController"))
        XCTAssertFalse(preferencesText.contains("final class ThemeCatalogViewController"))
        XCTAssertFalse(preferencesText.contains("final class ThemeEditorWindowController"))
        XCTAssertFalse(preferencesText.contains("final class ThemeEditorViewController"))

        XCTAssertTrue(catalogText.contains("final class ThemeCatalogWindowController"))
        XCTAssertTrue(catalogText.contains("final class ThemeCatalogViewController"))
        XCTAssertTrue(editorText.contains("final class ThemeEditorWindowController"))
        XCTAssertTrue(editorText.contains("final class ThemeEditorViewController"))
    }
}
