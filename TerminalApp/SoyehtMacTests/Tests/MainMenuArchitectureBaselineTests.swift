import AppKit
import Foundation
import XCTest
@testable import SoyehtMacDomain

final class MainMenuArchitectureBaselineTests: XCTestCase {

    func testMainMenuBuilderPublicNoWindowMenuMatchesGoldenFixture() throws {
        let snapshot = publicNoWindowSnapshot()
        let actual = try MainMenuSnapshot.encode(snapshot)

        if ProcessInfo.processInfo.environment["SOYEHT_RECORD_MENU_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.fixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actual.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
        }

        let expected = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        XCTAssertEqual(actual, expected)
    }

    func testPublicNoWindowMainMenuSurfaceMatchesReleaseContract() throws {
        let snapshot = publicNoWindowSnapshot()
        let titles = MainMenuSnapshot.titles(in: snapshot)

        XCTAssertEqual(
            PublicMenuSurface.forbiddenTitleFragments(in: titles),
            [],
            "Golden public menu contains forbidden release items: \(titles)"
        )
        XCTAssertEqual(
            PublicMenuSurface.missingRequiredTitleFragments(in: titles),
            [],
            "Golden public menu is missing required release items: \(titles)"
        )
    }

    func testMainMenuBuilderAssignsStableRuntimeIdentifiers() throws {
        let mainMenu = MainMenuBuilder().buildPublicNoWindowMenu()

        for id in [
            MainMenuID.app,
            .shell,
            .edit,
            .view,
            .pane,
            .workspaces,
            .sound,
            .window,
            .help,
        ] {
            let item = try XCTUnwrap(mainMenu.topLevelItem(id), "Missing top-level menu \(id)")
            XCTAssertEqual(item.representedObject as? MainMenuID, id)
            XCTAssertEqual(item.submenu?.identifier, MainMenuBuilder.identifier(for: id))
        }

        let paneMenu = try XCTUnwrap(mainMenu.topLevelItem(.pane)?.submenu)
        let movePane = try XCTUnwrap(
            paneMenu.items.first { $0.tag == AppCommandMenuTag.paneMoveToWorkspaceHeader }
        )
        XCTAssertEqual(movePane.identifier, MainMenuBuilder.identifier(for: .movePaneToWorkspace))
        XCTAssertEqual(movePane.representedObject as? MainMenuDynamicSectionID, .movePaneToWorkspace)
        XCTAssertEqual(movePane.submenu?.identifier, MainMenuBuilder.identifier(for: .movePaneToWorkspace))

        let soundMenu = try XCTUnwrap(mainMenu.topLevelItem(.sound)?.submenu)
        let dictationLanguage = try XCTUnwrap(
            soundMenu.items.first { $0.tag == MainMenuTag.soundDictationLanguage }
        )
        XCTAssertEqual(dictationLanguage.identifier, MainMenuBuilder.identifier(for: .dictationLanguage))
        XCTAssertEqual(dictationLanguage.representedObject as? MainMenuDynamicSectionID, .dictationLanguage)
        XCTAssertEqual(dictationLanguage.submenu?.identifier, MainMenuBuilder.identifier(for: .dictationLanguage))
    }

    func testMainMenuBuilderRoutesAppCommandsThroughSingleDispatcher() throws {
        let mainMenu = MainMenuBuilder().buildPublicNoWindowMenu()
        let commandItems = mainMenu.commandItems()

        XCTAssertFalse(commandItems.isEmpty)
        for item in commandItems {
            XCTAssertEqual(item.action, CommandDispatcher.action, item.title)
            XCTAssertNotNil(item.target, item.title)
            XCTAssertNotNil(item.representedObject as? AppCommandID, item.title)
        }
    }

    func testMacAppNoLongerDeclaresOrBundlesLegacyMainStoryboard() throws {
        let infoPlist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.infoPlistURL),
            options: [],
            format: nil
        ) as? [String: Any]
        XCTAssertNil(infoPlist?["NSMainStoryboardFile"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.legacyMainStoryboardURL.path))

        let project = try String(contentsOf: Self.projectFileURL, encoding: .utf8)
        XCTAssertFalse(project.contains("Main.storyboard"))
    }

    func testAppActivationReassertsProgrammaticMenuBeforeDebugMenu() throws {
        let source = try String(contentsOf: Self.appDelegateURL, encoding: .utf8)
        let activation = try slice(
            source,
            from: "func applicationDidBecomeActive",
            to: "private func autoHouseholdPairDevice"
        )

        let programmaticMenu = try XCTUnwrap(
            activation.range(of: "installProgrammaticMainMenuIfNeeded()")
        )
        let internalDebugMenu = try XCTUnwrap(
            activation.range(of: "installInternalDebugMenuIfNeeded()")
        )
        XCTAssertLessThan(
            programmaticMenu.lowerBound,
            internalDebugMenu.lowerBound,
            "The runtime builder must own the menu before DEBUG-only items are considered."
        )
    }

    func testRuntimeMenuOwnershipStaysInsideMainMenuBoundary() throws {
        let appDelegate = try String(contentsOf: Self.appDelegateURL, encoding: .utf8)
        let controller = try String(contentsOf: Self.mainMenuControllerURL, encoding: .utf8)
        let dynamicSections = try String(contentsOf: Self.dynamicMenuSectionsURL, encoding: .utf8)

        XCTAssertTrue(appDelegate.contains("private lazy var mainMenuController"))
        XCTAssertTrue(appDelegate.contains("mainMenuController.installProgrammaticMainMenu()"))
        XCTAssertTrue(appDelegate.contains("mainMenuController.installProgrammaticMainMenuIfNeeded()"))
        XCTAssertTrue(appDelegate.contains("mainMenuController.installInternalDebugMenuIfNeeded()"))

        for forbidden in [
            "NSMenuDelegate",
            "NSMenuItemValidation",
            "NSApp.mainMenu =",
            "func menuNeedsUpdate",
            "func validateMenuItem",
            "refreshMoveFocusedPaneMenu",
            "rebuildWorkspaceMenu",
            "refreshWorkspaceMenuEnhancements",
            "private func refreshSoundMenu",
            "private func installDebugMenu",
        ] {
            XCTAssertFalse(appDelegate.contains(forbidden), "AppDelegate should not own runtime menu code: \(forbidden)")
        }

        for required in [
            "final class MainMenuController",
            "NSMenuDelegate",
            "NSMenuItemValidation",
            "NSApp.mainMenu =",
            "func menuNeedsUpdate",
            "func validateMenuItem",
            "MovePaneMenuSectionBuilder",
            "WorkspaceMenuSectionBuilder",
            "DictationLanguageMenuSectionBuilder",
            "private func installDebugMenu",
        ] {
            XCTAssertTrue(controller.contains(required), "MainMenuController should own runtime menu code: \(required)")
        }

        for extracted in [
            "refreshMoveFocusedPaneMenu",
            "rebuildWorkspaceMenu",
            "refreshWorkspaceMenuEnhancements",
            "private func refreshSoundMenu",
            "private func makeMenuItem",
            "private func configureMenuItem",
            "private func disabledMenuItem",
            "private func collapseSeparators",
        ] {
            XCTAssertFalse(controller.contains(extracted), "Dynamic menu assembly should stay out of MainMenuController: \(extracted)")
        }

        for required in [
            "struct MovePaneMenuSectionBuilder",
            "struct WorkspaceMenuSectionBuilder",
            "struct DictationLanguageMenuSectionBuilder",
            "enum MainMenuItemFactory",
        ] {
            XCTAssertTrue(dynamicSections.contains(required), "DynamicMenuSections should own dynamic menu assembly: \(required)")
        }

        let runtimeMenuNeedles = [
            "NSApp.mainMenu",
            "NSMenuDelegate",
            "NSMenuItemValidation",
            "func menuNeedsUpdate",
            "func validateMenuItem",
        ]
        let offenders = try swiftSourcesOutsideMainMenu().compactMap { url -> String? in
            let source = try String(contentsOf: url, encoding: .utf8)
            return runtimeMenuNeedles.contains(where: source.contains)
                ? url.lastPathComponent
                : nil
        }
        XCTAssertEqual(offenders.sorted(), [], "Runtime menu ownership leaked outside MainMenu/: \(offenders)")
    }

    private func publicNoWindowSnapshot() -> MainMenuSnapshotNode {
        MainMenuSnapshot.capture(
            MainMenuBaseline.makePublicNoWindowMenu(),
            options: MainMenuBaseline.snapshotOptions()
        )
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Menu/PublicNoWindowMainMenu.golden.json")
    }

    private static var appDelegateURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac/AppDelegate.swift")
    }

    private static var mainMenuControllerURL: URL {
        soyehtMacURL
            .appendingPathComponent("MainMenu/MainMenuController.swift")
    }

    private static var dynamicMenuSectionsURL: URL {
        soyehtMacURL
            .appendingPathComponent("MainMenu/DynamicMenuSections.swift")
    }

    private static var soyehtMacURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac")
    }

    private static var infoPlistURL: URL {
        soyehtMacURL
            .appendingPathComponent("Info.plist")
    }

    private static var legacyMainStoryboardURL: URL {
        soyehtMacURL
            .appendingPathComponent("Base.lproj/Main.storyboard")
    }

    private static var projectFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac.xcodeproj/project.pbxproj")
    }

    private func swiftSourcesOutsideMainMenu() throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: Self.soyehtMacURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  url.pathExtension == "swift",
                  !url.path.contains("/MainMenu/") else { return nil }
            return url
        }
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}

private extension NSMenu {
    func topLevelItem(_ id: MainMenuID) -> NSMenuItem? {
        items.first { $0.identifier == MainMenuBuilder.identifier(for: id) }
    }

    func commandItems() -> [NSMenuItem] {
        items.flatMap { item -> [NSMenuItem] in
            var values: [NSMenuItem] = []
            if item.representedObject is AppCommandID {
                values.append(item)
            }
            if let submenu = item.submenu {
                values.append(contentsOf: submenu.commandItems())
            }
            return values
        }
    }
}
