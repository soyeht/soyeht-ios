import Testing
import SoyehtCore
import Foundation
@testable import Soyeht

@Suite(.serialized) struct HapticPreferencesTests {
    private let defaults = UserDefaults.standard
    private let prefs = TerminalPreferences.shared

    private enum Keys {
        static let hapticEnabled = "soyeht.terminal.hapticEnabled"
        static let hapticZoneConfigs = "soyeht.terminal.hapticZoneConfigs"
    }

    init() {
        defaults.removeObject(forKey: Keys.hapticEnabled)
        defaults.removeObject(forKey: Keys.hapticZoneConfigs)
    }

    // MARK: - Master Toggle

    @Test("hapticEnabled defaults to true when nothing stored")
    func defaultHapticEnabled() {
        defaults.removeObject(forKey: Keys.hapticEnabled)
        #expect(prefs.hapticEnabled == true)
    }

    @Test("hapticEnabled persists false when set")
    func hapticEnabledPersistsFalse() {
        prefs.hapticEnabled = false
        #expect(prefs.hapticEnabled == false)

        prefs.hapticEnabled = true
        #expect(prefs.hapticEnabled == true)
    }

    // MARK: - Zone Configs

    @Test("hapticType returns zone default when nothing stored")
    func defaultZoneTypes() {
        for zone in HapticZone.allCases {
            #expect(prefs.hapticType(for: zone) == zone.defaultType)
        }
    }

    @Test("setHapticType updates and persists correctly")
    func setAndGetHapticType() {
        prefs.setHapticType(.rigid, for: .clicky)
        #expect(prefs.hapticType(for: .clicky) == .rigid)
    }

    @Test("setHapticType does not affect other zones")
    func setDoesNotAffectOthers() {
        prefs.setHapticType(.success, for: .tactile)
        #expect(prefs.hapticType(for: .tactile) == .success)
        #expect(prefs.hapticType(for: .alphanumeric) == .light)
        #expect(prefs.hapticType(for: .clicky) == HapticZone.clicky.defaultType)
    }

    @Test("Round-trip: set all zones, read back, all match")
    func roundTripAllZones() {
        let assignments: [(HapticZone, HapticType)] = [
            (.alphanumeric, .heavy),
            (.clicky, .selectionChanged),
            (.tactile, .disabled),
            (.gestures, .warning),
        ]
        for (zone, type) in assignments {
            prefs.setHapticType(type, for: zone)
        }
        for (zone, type) in assignments {
            #expect(prefs.hapticType(for: zone) == type)
        }
    }

    @Test("Setting disabled works correctly")
    func disabledZone() {
        prefs.setHapticType(.disabled, for: .gestures)
        #expect(prefs.hapticType(for: .gestures) == .disabled)
    }
}
