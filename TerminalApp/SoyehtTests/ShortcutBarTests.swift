import Testing
import SoyehtCore
import Foundation
@testable import Soyeht

// MARK: - ShortcutBarItem Tests

@Suite struct ShortcutBarItemTests {

    @Test("Ctrl+D produces byte 0x04")
    func ctrlD() {
        let item = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "D")
        #expect(item.bytes == [0x04])
        #expect(item.label == "C-d")
        #expect(item.isCustom == true)
        #expect(item.kind == .send)
        #expect(item.group == .custom)
    }

    @Test("Ctrl+C produces byte 0x03")
    func ctrlC() {
        let item = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "C")
        #expect(item.bytes == [0x03])
        #expect(item.label == "C-c")
    }

    @Test("Ctrl+Z produces byte 0x1A")
    func ctrlZ() {
        let item = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "Z")
        #expect(item.bytes == [0x1A])
    }

    @Test("Alt+X produces ESC prefix + x")
    func altX() {
        let item = ShortcutBarItem.customShortcut(modifier: .alt, key: "X")
        #expect(item.bytes == [0x1B, 0x78])
        #expect(item.label == "M-x")
    }

    @Test("Custom label overrides auto-generated label")
    func customLabel() {
        let item = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "D", label: "EOF")
        #expect(item.label == "EOF")
    }

    @Test("Empty label falls back to auto-generated")
    func emptyLabelFallback() {
        let item = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "D", label: "")
        #expect(item.label == "C-d")
    }

    @Test("Custom shortcut IDs start with 'custom.'")
    func customIDPrefix() {
        let item = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "A")
        #expect(item.id.hasPrefix("custom."))
    }

    @Test("Text command produces UTF-8 bytes of the string")
    func textCommand() {
        let item = ShortcutBarItem.textCommand(text: "claude")
        #expect(item.bytes == Array("claude".utf8))
        #expect(item.label == "claude")
        #expect(item.description == "claude")
        #expect(item.isCustom == true)
    }

    @Test("Text command truncates auto-label at 8 chars")
    func textCommandLongLabel() {
        let item = ShortcutBarItem.textCommand(text: "docker compose up -d")
        #expect(item.label == "docker …")
    }

    @Test("Text command uses custom label when provided")
    func textCommandCustomLabel() {
        let item = ShortcutBarItem.textCommand(text: "git status", label: "gst")
        #expect(item.label == "gst")
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let item = ShortcutBarItem.customShortcut(
            modifier: .alt, key: "B", label: "M-b", description: "Back word"
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ShortcutBarItem.self, from: data)
        #expect(decoded == item)
    }
}

// MARK: - ShortcutBarCatalog Tests

@Suite struct ShortcutBarCatalogTests {

    @Test("allBuiltins has 14 items matching the real key bar")
    func builtinCount() {
        #expect(ShortcutBarCatalog.allBuiltins.count == 14)
    }

    @Test("defaultBarOrder has same count and IDs as allBuiltins")
    func defaultBarOrder() {
        let order = ShortcutBarCatalog.defaultBarOrder
        #expect(order.count == 14)
        #expect(order == ShortcutBarCatalog.allBuiltins.map(\.id))
    }

    @Test("allBuiltins includes PgUp and PgDn")
    func includesPaging() {
        let ids = ShortcutBarCatalog.allBuiltins.map(\.id)
        #expect(ids.contains("builtin.pgUp"))
        #expect(ids.contains("builtin.pgDn"))
    }

    @Test("Builtin IDs are unique")
    func uniqueIDs() {
        let ids = ShortcutBarCatalog.allBuiltins.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("resolve finds builtins by ID")
    func resolveBuiltin() {
        let item = ShortcutBarCatalog.resolve(id: "builtin.tab", customItems: [])
        #expect(item != nil)
        #expect(item?.label == "Tab")
    }

    @Test("resolve finds popular shortcuts by ID")
    func resolvePopular() {
        let item = ShortcutBarCatalog.resolve(id: "popular.ctrlD", customItems: [])
        #expect(item != nil)
        #expect(item?.bytes == [0x04])
    }

    @Test("resolve finds custom items")
    func resolveCustom() {
        let custom = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "W")
        let found = ShortcutBarCatalog.resolve(id: custom.id, customItems: [custom])
        #expect(found != nil)
        #expect(found?.id == custom.id)
    }

    @Test("resolve returns nil for unknown ID")
    func resolveUnknown() {
        let item = ShortcutBarCatalog.resolve(id: "nonexistent", customItems: [])
        #expect(item == nil)
    }

    @Test("popularShortcuts has 6 items")
    func popularCount() {
        #expect(ShortcutBarCatalog.popularShortcuts.count == 6)
    }

    @Test("Kill item has danger style")
    func killStyle() {
        let kill = ShortcutBarCatalog.builtinsByID["builtin.kill"]
        #expect(kill?.style == .danger)
    }

    @Test("Enter item has action style")
    func enterStyle() {
        let enter = ShortcutBarCatalog.builtinsByID["builtin.enter"]
        #expect(enter?.style == .action)
    }
}

// MARK: - Workflow Preset Tests

@Suite struct WorkflowPresetTests {

    @Test("All presets resolve their items without errors")
    func allPresetsResolve() {
        for preset in WorkflowPreset.allCases {
            let items = preset.resolvedItems()
            #expect(items.count == preset.keyCount, "Preset \(preset.displayName) resolved \(items.count) items but expected \(preset.keyCount)")
        }
    }

    @Test("tmux preset includes Prefix and Dtch items")
    func tmuxPresetExtras() {
        let items = WorkflowPreset.tmux.resolvedItems()
        let labels = items.map(\.label)
        #expect(labels.contains("Prefix"))
        #expect(labels.contains("Dtch"))
    }

    @Test("Preset keyCount matches itemIDs count")
    func keyCountMatchesIDs() {
        for preset in WorkflowPreset.allCases {
            #expect(preset.keyCount == preset.itemIDs.count)
        }
    }
}

// MARK: - Preferences Integration Tests

@Suite(.serialized) struct ShortcutBarPreferencesTests {
    private let defaults = UserDefaults.standard
    private let prefs = TerminalPreferences.shared

    private enum Keys {
        static let activeIDs = "soyeht.terminal.shortcutBarActiveIDs"
        static let customItems = "soyeht.terminal.shortcutBarCustomItems"
    }

    init() {
        defaults.removeObject(forKey: Keys.activeIDs)
        defaults.removeObject(forKey: Keys.customItems)
    }

    @Test("Default activeIDs matches catalog defaultBarOrder")
    func defaultActiveIDs() {
        #expect(prefs.shortcutBarActiveIDs == ShortcutBarCatalog.defaultBarOrder)
    }

    @Test("Default resolved items has 14 items")
    func defaultResolvedItems() {
        let items = prefs.resolvedActiveItems()
        #expect(items.count == 14)
    }

    @Test("Default shortcutBarLabel is 'Default'")
    func defaultLabel() {
        #expect(prefs.shortcutBarLabel == "Default")
    }

    @Test("Custom activeIDs changes label to 'Custom'")
    func customLabel() {
        prefs.shortcutBarActiveIDs = ["builtin.tab", "builtin.esc", "builtin.enter"]
        #expect(prefs.shortcutBarLabel == "Custom (3)")
    }

    @Test("resolvedActiveItems skips unknown IDs gracefully")
    func skipsUnknownIDs() {
        prefs.shortcutBarActiveIDs = ["builtin.tab", "nonexistent.id", "builtin.esc"]
        let items = prefs.resolvedActiveItems()
        #expect(items.count == 2)
        #expect(items[0].id == "builtin.tab")
        #expect(items[1].id == "builtin.esc")
    }

    @Test("Custom shortcuts persist separately from activeIDs")
    func customShortcutsPersistSeparately() {
        let custom = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "D", description: "EOF")
        prefs.shortcutBarCustomItems = [custom]

        // Add custom to active
        var ids = ShortcutBarCatalog.defaultBarOrder
        ids.append(custom.id)
        prefs.shortcutBarActiveIDs = ids

        // Resolve — should find the custom item
        let items = prefs.resolvedActiveItems()
        #expect(items.count == 15)
        #expect(items.last?.id == custom.id)
    }

    @Test("Removing custom from activeIDs keeps it in customShortcuts")
    func removeFromActiveKeepsCustom() {
        let custom = ShortcutBarItem.customShortcut(modifier: .ctrl, key: "Z")
        prefs.shortcutBarCustomItems = [custom]
        prefs.shortcutBarActiveIDs = [custom.id]

        // Remove from active
        prefs.shortcutBarActiveIDs = []

        // Custom items still persisted
        #expect(prefs.shortcutBarCustomItems.count == 1)
        #expect(prefs.shortcutBarCustomItems[0].id == custom.id)
    }

    @Test("Default customShortcuts is empty")
    func defaultCustomShortcutsEmpty() {
        #expect(prefs.shortcutBarCustomItems.isEmpty)
    }
}
