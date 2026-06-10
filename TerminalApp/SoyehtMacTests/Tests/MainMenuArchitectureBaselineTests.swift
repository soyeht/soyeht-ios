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

    func testLegacyStoryboardCanonicalizationsAreExplicitAndCurrent() throws {
        let storyboardItems = try StoryboardMenuScanner(storyboardURL: Self.storyboardURL).itemsBySelector

        XCTAssertFalse(LegacyMainMenuBaseline.canonicalizations.isEmpty)

        for canonicalization in LegacyMainMenuBaseline.canonicalizations {
            XCTAssertTrue(
                canonicalization.changesStoryboardContract,
                "\(canonicalization.label) does not document a real storyboard-to-runtime change."
            )

            let storyboardItem = try XCTUnwrap(
                storyboardItems[canonicalization.storyboardSelector]?.first(where: {
                    $0.title == canonicalization.storyboardTitle
                }),
                "Missing storyboard item for \(canonicalization.label)"
            )
            XCTAssertEqual(storyboardItem.shortcut, canonicalization.storyboardShortcut, canonicalization.label)

            if let commandID = canonicalization.commandID {
                let command = try XCTUnwrap(AppCommandRegistry.command(commandID), "Missing command \(commandID)")
                XCTAssertEqual(command.title, canonicalization.canonicalTitle, canonicalization.label)
                XCTAssertEqual(command.action.rawValue, canonicalization.canonicalSelector, canonicalization.label)
                XCTAssertEqual(command.shortcut.map(MenuShortcutSnapshot.init), canonicalization.canonicalShortcut, canonicalization.label)
            }
        }
    }

    private func publicNoWindowSnapshot() -> MainMenuSnapshotNode {
        MainMenuSnapshot.capture(
            MainMenuBuilder().buildPublicNoWindowMenu(),
            options: LegacyMainMenuBaseline.snapshotOptions()
        )
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Menu/PublicNoWindowMainMenu.golden.json")
    }

    private static var storyboardURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac/Base.lproj/Main.storyboard")
    }
}

private struct StoryboardMenuScanner {
    struct Item {
        let title: String
        let selector: String
        let shortcut: MenuShortcutSnapshot?
    }

    let itemsBySelector: [String: [Item]]

    init(storyboardURL: URL) throws {
        let document = try XMLDocument(contentsOf: storyboardURL, options: [])
        guard let root = document.rootElement() else {
            throw NSError(
                domain: "MainMenuArchitectureBaselineTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Storyboard has no root element."]
            )
        }

        var items: [String: [Item]] = [:]
        Self.collectItems(in: root, into: &items)
        self.itemsBySelector = items
    }

    private static func collectItems(in element: XMLElement, into items: inout [String: [Item]]) {
        if element.name == "menuItem",
           let selector = directActionSelector(in: element) {
            let item = Item(
                title: element.attribute(forName: "title")?.stringValue ?? "",
                selector: selector,
                shortcut: shortcut(in: element)
            )
            items[selector, default: []].append(item)
        }

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            collectItems(in: childElement, into: &items)
        }
    }

    private static func directActionSelector(in menuItem: XMLElement) -> String? {
        for connections in menuItem.elements(forName: "connections") {
            for action in connections.elements(forName: "action") {
                if let selector = action.attribute(forName: "selector")?.stringValue {
                    return selector
                }
            }
        }
        return nil
    }

    private static func shortcut(in menuItem: XMLElement) -> MenuShortcutSnapshot? {
        guard let rawKey = rawKeyEquivalent(in: menuItem), !rawKey.isEmpty else { return nil }

        let explicitModifiers = explicitModifierNames(in: menuItem)
        if let explicitModifiers {
            return MenuShortcutSnapshot(
                key: MenuShortcutSnapshot.snapshotKey(forMenuKeyEquivalent: rawKey),
                modifiers: explicitModifiers
            )
        }

        var modifiers = ["command"]
        let normalizedKey: String
        if rawKey.count == 1,
           let scalar = rawKey.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(scalar) {
            modifiers.append("shift")
            normalizedKey = rawKey.lowercased()
        } else {
            normalizedKey = MenuShortcutSnapshot.snapshotKey(forMenuKeyEquivalent: rawKey)
        }
        return MenuShortcutSnapshot(key: normalizedKey, modifiers: modifiers)
    }

    private static func rawKeyEquivalent(in menuItem: XMLElement) -> String? {
        if let attribute = menuItem.attribute(forName: "keyEquivalent")?.stringValue {
            return attribute
        }

        for string in menuItem.elements(forName: "string") {
            guard string.attribute(forName: "key")?.stringValue == "keyEquivalent" else { continue }
            let value = string.stringValue ?? ""
            if string.attribute(forName: "base64-UTF8")?.stringValue == "YES" {
                return decodeInterfaceBuilderBase64(value)
            }
            return value
        }
        return nil
    }

    private static func explicitModifierNames(in menuItem: XMLElement) -> [String]? {
        guard let modifierMask = menuItem
            .elements(forName: "modifierMask")
            .first(where: { $0.attribute(forName: "key")?.stringValue == "keyEquivalentModifierMask" })
        else { return nil }

        var modifiers: [String] = []
        if modifierMask.attribute(forName: "command")?.stringValue == "YES" { modifiers.append("command") }
        if modifierMask.attribute(forName: "shift")?.stringValue == "YES" { modifiers.append("shift") }
        if modifierMask.attribute(forName: "option")?.stringValue == "YES" { modifiers.append("option") }
        if modifierMask.attribute(forName: "control")?.stringValue == "YES" { modifiers.append("control") }
        return modifiers
    }

    private static func decodeInterfaceBuilderBase64(_ value: String) -> String? {
        let remainder = value.count % 4
        let padded = remainder == 0 ? value : value + String(repeating: "=", count: 4 - remainder)
        guard let data = Data(base64Encoded: padded), let byte = data.first else { return nil }
        switch byte {
        case 0x1C: return "\u{F702}"
        case 0x1D: return "\u{F703}"
        case 0x1E: return "\u{F700}"
        case 0x1F: return "\u{F701}"
        default:
            return String(bytes: [byte], encoding: .utf8)
        }
    }
}
