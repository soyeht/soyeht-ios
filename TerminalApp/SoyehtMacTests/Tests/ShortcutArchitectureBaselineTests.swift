import Foundation
import XCTest
@testable import SoyehtMacDomain

final class ShortcutArchitectureBaselineTests: XCTestCase {
    func testAppCommandShortcutsHaveSingleCanonicalProductionDefinition() throws {
        let commands = AppCommandRegistry.allCommands
        XCTAssertEqual(
            Set(commands.map(\.id)).count,
            commands.count,
            "Each AppCommandID should have exactly one registry descriptor."
        )
        XCTAssertTrue(
            AppCommandRegistry.duplicateShortcuts().isEmpty,
            "Shortcut collisions should be resolved in AppCommandRegistry before reaching menus or local monitors."
        )

        let offenders = try swiftSources().compactMap { url -> String? in
            let relativePath = try relativeSoyehtMacPath(for: url)
            guard !relativePath.hasSuffix("App/AppCommandRegistry.swift"),
                  !relativePath.hasSuffix("MainMenu/MenuModel.swift") else {
                return nil
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            return source.contains("AppCommandShortcut(") ? relativePath : nil
        }

        XCTAssertEqual(
            offenders.sorted(),
            [],
            "App command shortcut definitions should stay canonical in AppCommandRegistry. MainMenu/MenuModel.swift is allowed for system/responder-chain roles."
        )
    }

    func testPaneGridShortcutSurfaceMatchesRouterRegistryAndGridHandler() throws {
        let registryIDs = Set(AppCommandRegistry.commands(in: .paneGrid).map(\.id))
        XCTAssertEqual(registryIDs, Set(Self.paneGridCommandIDs))

        for id in Self.paneGridCommandIDs {
            let command = try command(id)
            XCTAssertEqual(
                lookup(command, in: .paneGrid)?.id,
                id,
                "Pane grid shortcut lookup should resolve \(id) through AppCommandRegistry."
            )
        }

        let source = try macSource("PaneGrid/PaneGridController.swift")
        let installKeyMonitor = try slice(
            source,
            from: "private func installKeyMonitor()",
            to: "private func installMouseMonitor()"
        )
        let handler = try slice(
            source,
            from: "private func handleGridShortcut",
            to: "\n    }\n}"
        )

        XCTAssertTrue(source.contains("private let shortcutRouter = AppCommandShortcutRouter()"))
        XCTAssertTrue(installKeyMonitor.contains("shortcutRouter.commandID(matching: event, in: .paneGrid)"))
        XCTAssertFalse(source.contains("AppCommandRegistry.command(matching: event, in: .paneGrid)"))

        let handledCases = Set(try swiftCaseNames(in: handler))
        XCTAssertEqual(
            handledCases,
            Set(Self.paneGridCommandIDs.map(Self.swiftCaseName)),
            "PaneGridController should accept exactly the shortcut commands declared for the paneGrid registry context."
        )

        let registrySource = try macSource("App/AppCommandRegistry.swift")
        let router = try slice(
            registrySource,
            from: "struct AppCommandShortcutRouter",
            to: "#if canImport(AppKit)"
        )
        XCTAssertTrue(router.contains("AppCommandRegistry.command("))

        XCTAssertFalse(
            registrySource.contains("static func command(matching event"),
            "NSEvent -> AppCommand lookup should live only in AppCommandShortcutRouter, not AppCommandRegistry."
        )
        let appKitRouter = try slice(
            registrySource,
            from: "extension AppCommandShortcutRouter",
            to: "#endif"
        )
        XCTAssertTrue(appKitRouter.contains("func command(matching event: NSEvent"))
        XCTAssertTrue(appKitRouter.contains("matchingKeyCode: event.keyCode"))
        XCTAssertTrue(appKitRouter.contains("charactersIgnoringModifiers: event.charactersIgnoringModifiers"))
        XCTAssertTrue(appKitRouter.contains("modifiers: AppCommandModifier(event.modifierFlags)"))
        XCTAssertFalse(appKitRouter.contains("AppCommandRegistry.command(matching: event"))
    }

    func testMutableWindowScopedCommandsHaveBaselineValidationCoverage() throws {
        let noWindow = CommandUIContext()
        let window = MainWindowCommandUIState(
            workspaceCount: 2,
            activeWorkspaceTag: 1,
            selectableWorkspaceTags: Set(AppCommandRegistry.workspaceTags),
            moveFocusedPaneDestinationTags: Set(AppCommandRegistry.workspaceTags),
            canMoveActiveWorkspaceLeft: true,
            canMoveActiveWorkspaceRight: true,
            paneGrid: PaneCommandUIState(
                canActOnFocusedPane: true,
                hasZoomedPane: true,
                canRotateFocusedSplit: true,
                focusableDirections: [.left, .right, .up, .down],
                swappableDirections: [.left, .right, .up, .down]
            )
        )
        let scopedWindow = CommandUIContext(
            frontmostWindow: window,
            activeWindow: window,
            undo: UndoCommandUIState(canUndo: true, canRedo: true)
        )

        for id in Self.mutableWindowScopedCommandIDs {
            XCTAssertFalse(
                try command(id).isEnabled(in: noWindow),
                "\(id) should not be enabled without a scoped UI window."
            )
            XCTAssertTrue(
                try command(id).isEnabled(in: scopedWindow),
                "\(id) should be enabled when the frontmost window context supports it."
            )
        }

        XCTAssertFalse(MainMenuExplicitRole.closeWorkspace.validation(in: noWindow).isEnabled)
        XCTAssertTrue(MainMenuExplicitRole.closeWorkspace.validation(in: scopedWindow).isEnabled)
    }

    func testMutableUICommandPathDoesNotUseAutomationWindowFallbacks() throws {
        let appDelegate = try macSource("AppDelegate.swift")
        let mainMenuController = try macSource("MainMenu/MainMenuController.swift")

        let uiResolver = try slice(
            appDelegate,
            from: "fileprivate static func uiMainWindowController()",
            to: "fileprivate static func mainWindowCommandTargetResolver"
        )
        let targetResolver = try slice(
            appDelegate,
            from: "fileprivate static func mainWindowCommandTargetResolver",
            to: "fileprivate static func mainWindowController"
        )
        assertNoArbitraryWindowFallbacks(uiResolver, label: "uiMainWindowController")
        assertNoArbitraryWindowFallbacks(targetResolver, label: "mainWindowCommandTargetResolver")

        let mutableActions = try slice(
            appDelegate,
            from: "@IBAction func moveFocusedPaneToWorkspaceByTag",
            to: "@IBAction func showClawStore"
        )
        assertNoArbitraryWindowFallbacks(mutableActions, label: "mutable AppDelegate UI actions")
        XCTAssertTrue(mutableActions.contains("uiMainWindowController"))
        XCTAssertTrue(mutableActions.contains("uiMainWindowController?.moveActiveWorkspaceLeft"))
        XCTAssertTrue(mutableActions.contains("uiMainWindowController?.moveActiveWorkspaceRight"))

        let paneGridBridge = try slice(
            appDelegate,
            from: "private func withActivePaneGrid",
            to: "/// Menu item / `⌘⇧C` target."
        )
        assertNoArbitraryWindowFallbacks(paneGridBridge, label: "AppDelegate pane grid bridge")
        XCTAssertTrue(paneGridBridge.contains("guard let grid = uiMainWindowController?.activeGridController"))

        let menuContext = try slice(
            mainMenuController,
            from: "private var commandUIContext",
            to: "private func commandWindowState"
        )
        assertNoArbitraryWindowFallbacks(menuContext, label: "MainMenuController command UI context")
        XCTAssertTrue(menuContext.contains("let uiController = uiMainWindowController"))
        XCTAssertTrue(menuContext.contains("activeWindow: uiState"))

        let workspaceState = try slice(
            mainMenuController,
            from: "private var workspaceSectionState",
            to: "private func workspaceEntries"
        )
        assertNoArbitraryWindowFallbacks(workspaceState, label: "MainMenuController workspace dynamic state")
        XCTAssertTrue(workspaceState.contains("let controller = uiMainWindowController"))
    }

    func testAutomationWindowFallbackIsExplicitlySeparatedFromUIScope() throws {
        let appDelegate = try macSource("AppDelegate.swift")
        let activeWindow = try slice(
            appDelegate,
            from: "var activeMainWindowController: SoyehtMainWindowController?",
            to: "func retainMenuWindowController"
        )

        XCTAssertTrue(activeWindow.contains("automationMainWindowController"))
        XCTAssertTrue(activeWindow.contains("automationFallback: mainWindowControllers.first"))
        XCTAssertTrue(activeWindow.contains(".automationTarget"))
        XCTAssertFalse(activeWindow.contains("NSApp.orderedWindows"))
    }

    func testCommandPaletteJumpUsesUICommandScopeWithoutAutomationFallback() throws {
        let appDelegate = try macSource("AppDelegate.swift")
        let jump = try slice(
            appDelegate,
            from: "private func jump(to item: CommandPaletteItem)",
            to: "\n    }\n\n"
        )

        XCTAssertTrue(jump.contains("guard let target = uiMainWindowController"))
        XCTAssertFalse(jump.contains("activeMainWindowController"))
        XCTAssertFalse(jump.contains("NSApp.orderedWindows"))
        XCTAssertFalse(jump.contains("mainWindowControllers.first"))
    }

    private static let paneGridCommandIDs: [AppCommandID] = [
        .focusPaneLeft,
        .focusPaneRight,
        .focusPaneUp,
        .focusPaneDown,
        .toggleZoomFocusedPane,
        .exitZoom,
        .swapPaneLeft,
        .swapPaneRight,
        .swapPaneUp,
        .swapPaneDown,
        .rotateFocusedSplit,
    ]

    private static var mutableWindowScopedCommandIDs: [AppCommandID] {
        [
            .undoWindowAction,
            .redoWindowAction,
            .splitPaneVertical,
            .splitPaneHorizontal,
            .closeFocusedPane,
            .focusPaneLeft,
            .focusPaneRight,
            .focusPaneUp,
            .focusPaneDown,
            .toggleZoomFocusedPane,
            .exitZoom,
            .swapPaneLeft,
            .swapPaneRight,
            .swapPaneUp,
            .swapPaneDown,
            .rotateFocusedSplit,
            .moveActiveWorkspaceLeft,
            .moveActiveWorkspaceRight,
        ]
        + AppCommandRegistry.workspaceTags.map { .selectWorkspace($0) }
        + AppCommandRegistry.workspaceTags.map { .moveFocusedPaneToWorkspace($0) }
    }

    private func command(_ id: AppCommandID) throws -> AppCommand {
        try XCTUnwrap(AppCommandRegistry.command(id), "Missing command \(id)")
    }

    private func lookup(_ command: AppCommand, in context: AppCommandContext) -> AppCommand? {
        guard let shortcut = command.shortcut else { return nil }
        return AppCommandShortcutRouter().command(
            matchingKeyCode: shortcut.lookupKeyCode,
            charactersIgnoringModifiers: shortcut.lookupCharacters,
            modifiers: shortcut.modifiers,
            in: context
        )
    }

    private func assertNoArbitraryWindowFallbacks(
        _ source: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in ["NSApp.orderedWindows", "mainWindowControllers.first", "activeMainWindowController"] {
            XCTAssertFalse(
                source.contains(forbidden),
                "\(label) should not use arbitrary automation/headless window fallback: \(forbidden)",
                file: file,
                line: line
            )
        }
    }

    private func swiftCaseNames(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"case \.([A-Za-z0-9_]+)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[matchRange])
        }
    }

    private static func swiftCaseName(for id: AppCommandID) -> String {
        let description = id.description
        return description.split(separator: "(").first.map(String.init) ?? description
    }

    private func macSource(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.soyehtMacURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources() throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: Self.soyehtMacURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private func relativeSoyehtMacPath(for url: URL) throws -> String {
        let root = Self.soyehtMacURL.path + "/"
        let path = url.path
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count))
    }

    private static var soyehtMacURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac")
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}

private extension AppCommandShortcut {
    var lookupKeyCode: UInt16 {
        switch key {
        case .character:
            return 0
        case .special(let special):
            return special.virtualKeyCode
        }
    }

    var lookupCharacters: String? {
        switch key {
        case .character(let value):
            return value
        case .special:
            return nil
        }
    }
}
