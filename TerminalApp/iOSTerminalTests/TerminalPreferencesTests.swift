import Testing
import Foundation
@testable import iOSTerminal

@Suite(.serialized) struct TerminalPreferencesTests {
    private let testKey = "soyeht.terminal.fontSize"

    init() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    @Test("Default font size is 13 when nothing is stored")
    func defaultFontSize() {
        UserDefaults.standard.removeObject(forKey: testKey)
        let prefs = TerminalPreferences.shared
        #expect(prefs.fontSize == 13)
    }

    @Test("Saves and loads custom font size")
    func saveAndLoadFontSize() {
        let prefs = TerminalPreferences.shared
        prefs.fontSize = 18
        #expect(prefs.fontSize == 18)

        prefs.fontSize = 8
        #expect(prefs.fontSize == 8)

        prefs.fontSize = 24
        #expect(prefs.fontSize == 24)
    }

    @Test("Returns default when stored value is 0 or negative")
    func ignoresInvalidValues() {
        let prefs = TerminalPreferences.shared
        UserDefaults.standard.set(0, forKey: testKey)
        #expect(prefs.fontSize == 13)

        UserDefaults.standard.set(-5.0, forKey: testKey)
        #expect(prefs.fontSize == 13)
    }
}
