import Testing
import SoyehtCore
import Foundation
@testable import Soyeht

@Suite(.serialized) struct TerminalPreferencesTests {
    private let defaults = UserDefaults.standard
    private let prefs = TerminalPreferences.shared

    private enum Keys {
        static let fontSize = "soyeht.terminal.fontSize"
        static let cursorStyle = "soyeht.terminal.cursorStyle"
        static let cursorColorHex = "soyeht.terminal.cursorColorHex"
        static let recentCustomColors = "soyeht.terminal.recentCustomColors"
        static let paneNicknames = "soyeht.terminal.paneNicknames"
    }

    init() {
        defaults.removeObject(forKey: Keys.fontSize)
        defaults.removeObject(forKey: Keys.cursorStyle)
        defaults.removeObject(forKey: Keys.cursorColorHex)
        defaults.removeObject(forKey: Keys.recentCustomColors)
        defaults.removeObject(forKey: Keys.paneNicknames)
    }

    // MARK: - Font Size

    @Test("Default font size is 13 when nothing is stored")
    func defaultFontSize() {
        defaults.removeObject(forKey: Keys.fontSize)
        #expect(prefs.fontSize == 13)
    }

    @Test("Saves and loads custom font size")
    func saveAndLoadFontSize() {
        prefs.fontSize = 18
        #expect(prefs.fontSize == 18)

        prefs.fontSize = 8
        #expect(prefs.fontSize == 8)

        prefs.fontSize = 24
        #expect(prefs.fontSize == 24)
    }

    @Test("Returns default when stored value is 0 or negative")
    func ignoresInvalidValues() {
        defaults.set(0, forKey: Keys.fontSize)
        #expect(prefs.fontSize == 13)

        defaults.set(-5.0, forKey: Keys.fontSize)
        #expect(prefs.fontSize == 13)
    }

    // MARK: - Cursor Style

    @Test("Default cursor style is blinkBlock when nothing is stored")
    func defaultCursorStyle() {
        #expect(prefs.cursorStyle == "blinkBlock")
    }

    @Test("Saves and loads custom cursor style")
    func saveAndLoadCursorStyle() {
        prefs.cursorStyle = "steadyBar"
        #expect(prefs.cursorStyle == "steadyBar")

        prefs.cursorStyle = "blinkUnderline"
        #expect(prefs.cursorStyle == "blinkUnderline")
    }

    // MARK: - Cursor Color

    @Test("Default cursor color is #10B981 when nothing is stored")
    func defaultCursorColor() {
        #expect(prefs.cursorColorHex == "#10B981")
    }

    @Test("Saves and loads custom cursor color")
    func saveAndLoadCursorColor() {
        prefs.cursorColorHex = "#3B82F6"
        #expect(prefs.cursorColorHex == "#3B82F6")
    }

    // MARK: - Recent Custom Colors

    @Test("Recent custom colors starts empty")
    func recentColorsEmpty() {
        #expect(prefs.recentCustomColors.isEmpty)
    }

    @Test("addRecentCustomColor prepends and caps at 5")
    func recentColorsCapsAtFive() {
        prefs.addRecentCustomColor("#111111")
        prefs.addRecentCustomColor("#222222")
        prefs.addRecentCustomColor("#333333")
        prefs.addRecentCustomColor("#444444")
        prefs.addRecentCustomColor("#555555")
        prefs.addRecentCustomColor("#666666")

        let recent = prefs.recentCustomColors
        #expect(recent.count == 5)
        #expect(recent[0] == "#666666")
        #expect(recent[4] == "#222222")
    }

    @Test("addRecentCustomColor deduplicates case-insensitively")
    func recentColorsDeduplicates() {
        prefs.addRecentCustomColor("#10B981")
        prefs.addRecentCustomColor("#AABBCC")
        prefs.addRecentCustomColor("#10b981")

        let recent = prefs.recentCustomColors
        #expect(recent.count == 2)
        #expect(recent[0] == "#10b981")
    }

    // MARK: - Pane Nicknames

    @Test("paneNickname returns nil when no nickname is set")
    func paneNickname_returnsNilWhenEmpty() {
        let result = prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 99)
        #expect(result == nil)
    }

    @Test("paneNickname stores and retrieves by paneId")
    func paneNickname_storesAndRetrievesByPaneId() {
        prefs.setPaneNickname("alpha", container: "c", session: "s", window: 0, paneId: 5)
        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 5) == "alpha")
    }

    @Test("Different paneIds have independent nicknames")
    func paneNickname_independentByPaneId() {
        prefs.setPaneNickname("alpha", container: "c", session: "s", window: 0, paneId: 5)
        prefs.setPaneNickname("beta", container: "c", session: "s", window: 0, paneId: 6)

        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 5) == "alpha")
        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 6) == "beta")
    }

    @Test("Setting nil removes the nickname")
    func paneNickname_settingNilRemoves() {
        prefs.setPaneNickname("alpha", container: "c", session: "s", window: 0, paneId: 5)
        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 5) == "alpha")

        prefs.setPaneNickname(nil, container: "c", session: "s", window: 0, paneId: 5)
        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 5) == nil)
    }

    @Test("Nicknames survive pane kill and index renumber")
    func paneNickname_survivesPaneKillAndRenumber() {
        // Simulate: 3 panes with stable paneIds 5, 6, 7
        prefs.setPaneNickname("alpha", container: "c", session: "s", window: 0, paneId: 5)
        prefs.setPaneNickname("beta", container: "c", session: "s", window: 0, paneId: 6)
        prefs.setPaneNickname("gamma", container: "c", session: "s", window: 0, paneId: 7)

        // Simulate killing pane with paneId=6 (beta)
        prefs.setPaneNickname(nil, container: "c", session: "s", window: 0, paneId: 6)

        // After kill, tmux renumbers indices but paneIds are stable
        // alpha (paneId 5) and gamma (paneId 7) must survive untouched
        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 5) == "alpha")
        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 6) == nil)
        #expect(prefs.paneNickname(container: "c", session: "s", window: 0, paneId: 7) == "gamma")
    }

    @Test("Key format uses :pid: separator and does not collide with old index-based format")
    func paneNickname_keyUsesStableId() {
        // Store with new paneId-based API
        prefs.setPaneNickname("new-format", container: "c", session: "s", window: 0, paneId: 1)

        // Old format would have stored at key "c:s:0:1" — manually check it's NOT there
        let data = defaults.data(forKey: Keys.paneNicknames)!
        let dict = try! JSONDecoder().decode([String: String].self, from: data)

        // New key should be "c:s:0:pid:1"
        #expect(dict["c:s:0:pid:1"] == "new-format")
        // Old key format should not exist
        #expect(dict["c:s:0:1"] == nil)
    }
}
