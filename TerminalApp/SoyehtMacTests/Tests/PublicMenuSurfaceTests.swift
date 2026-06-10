import AppKit
import XCTest
@testable import SoyehtMacDomain

final class PublicMenuSurfaceTests: XCTestCase {

    func testPublicMenuSurfaceRemovesInternalAndUnreleasedItems() {
        let mainMenu = makeRepresentativeMainMenu()

        PublicMenuSurface.removeForbiddenPublicItems(
            from: mainMenu,
            allowInternalDebugMenu: false,
            localizedDebugTitle: "Debug"
        )

        let titles = PublicMenuSurface.allMenuItemTitles(in: mainMenu)
        XCTAssertEqual(
            PublicMenuSurface.forbiddenTitleFragments(in: titles),
            [],
            "Public menu still contains internal or unreleased items: \(titles)"
        )
        XCTAssertEqual(
            PublicMenuSurface.missingRequiredTitleFragments(in: titles),
            [],
            "Public menu is missing expected release menu items: \(titles)"
        )
    }

    func testPublicMenuSurfaceCollapsesDuplicateSystemItems() {
        let mainMenu = NSMenu(title: "Main Menu")
        addMenu("Edit", items: [
            "Undo",
            "Start Dictation…",
            "Start Dictation…",
            "Emoji & Symbols",
            "Emoji & Symbols"
        ], to: mainMenu)
        addMenu("View", items: [
            "Actual Size",
            "Enter Full Screen",
            "Enter Full Screen"
        ], to: mainMenu)

        PublicMenuSurface.removeDuplicateVisibleItems(from: mainMenu)

        let titles = PublicMenuSurface.allMenuItemTitles(in: mainMenu)
        XCTAssertEqual(titles.filter { $0 == "Start Dictation…" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Emoji & Symbols" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Enter Full Screen" }.count, 1)
    }

    func testReleaseBuildNeverHonorsInternalDebugOverrides() {
        let defaults = UserDefaults(suiteName: "PublicMenuSurfaceTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: PublicMenuSurface.internalDebugDefaultsKey)
        defer {
            defaults.removeObject(forKey: PublicMenuSurface.internalDebugDefaultsKey)
        }

        XCTAssertFalse(
            PublicMenuSurface.shouldShowInternalDebugMenu(
                isDevelopmentBuild: false,
                environment: [PublicMenuSurface.internalDebugEnvironmentKey: "1"],
                userDefaults: defaults
            )
        )
    }

    func testDevelopmentBuildHonorsExplicitInternalDebugOverrides() {
        let defaults = UserDefaults(suiteName: "PublicMenuSurfaceTests.\(UUID().uuidString)")!
        defer {
            defaults.removeObject(forKey: PublicMenuSurface.internalDebugDefaultsKey)
        }

        XCTAssertTrue(
            PublicMenuSurface.shouldShowInternalDebugMenu(
                isDevelopmentBuild: true,
                environment: [PublicMenuSurface.internalDebugEnvironmentKey: "1"],
                userDefaults: defaults
            )
        )

        defaults.set(true, forKey: PublicMenuSurface.internalDebugDefaultsKey)
        XCTAssertTrue(
            PublicMenuSurface.shouldShowInternalDebugMenu(
                isDevelopmentBuild: true,
                environment: [:],
                userDefaults: defaults
            )
        )
    }

    private func makeRepresentativeMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")
        addMenu("Soyeht", items: ["About Soyeht", "Settings…", "Agent Permissions…"], to: mainMenu)
        addMenu("Shell", items: ["New Window", "Export Text As...", "Export Selected Text As...", "Soft Reset", "Hard Reset"], to: mainMenu)
        addMenu("Edit", items: ["Undo", "Debug", "Cut", "Copy", "Paste"], to: mainMenu)
        addMenu("View", items: ["Actual Size", "Use Base16 LAB 256 Palette"], to: mainMenu)
        addMenu("Pane", items: ["Split Vertical", "Move Focused Pane 2", "Move Pane to Workspace"], to: mainMenu)
        addMenu("Workspaces", items: ["Show Workspace Sidebar", "Workspaces"], to: mainMenu)
        addMenu("Window", items: ["Minimize", "Zoom", "Bring All to Front"], to: mainMenu)
        addMenu("Debug", items: ["Show Debug Buffer"], to: mainMenu)
        addMenu("Help", items: ["Soyeht Help"], to: mainMenu)
        return mainMenu
    }

    private func addMenu(_ title: String, items: [String], to mainMenu: NSMenu) {
        let topLevelItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for itemTitle in items {
            submenu.addItem(NSMenuItem(title: itemTitle, action: nil, keyEquivalent: ""))
        }
        topLevelItem.submenu = submenu
        mainMenu.addItem(topLevelItem)
    }
}
