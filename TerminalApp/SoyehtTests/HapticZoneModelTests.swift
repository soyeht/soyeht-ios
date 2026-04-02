import Testing
import Foundation
@testable import Soyeht

@Suite struct HapticZoneModelTests {

    // MARK: - HapticType

    @Test("Default haptic types match spec")
    func defaultHapticTypes() {
        #expect(HapticZone.alphanumeric.defaultType == .light)
        #expect(HapticZone.clicky.defaultType == .heavy)
        #expect(HapticZone.tactile.defaultType == .medium)
        #expect(HapticZone.gestures.defaultType == .selectionChanged)
    }

    @Test("displayName starts with dot for all except disabled")
    func displayNameFormat() {
        for type in HapticType.allCases {
            if type == .disabled {
                #expect(type.displayName == "Disabled")
            } else {
                #expect(type.displayName.hasPrefix("."))
            }
        }
    }

    @Test("Every HapticType has a category")
    func allTypesHaveCategory() {
        for type in HapticType.allCases {
            _ = type.category // should not crash
        }
        #expect(HapticType.light.category == .impact)
        #expect(HapticType.selectionChanged.category == .selection)
        #expect(HapticType.success.category == .notification)
        #expect(HapticType.disabled.category == .none)
    }

    @Test("groupedOptions contains all cases exactly once")
    func groupedOptionsComplete() {
        let allFromGroups = HapticType.groupedOptions.flatMap { $0.types }
        #expect(allFromGroups.count == HapticType.allCases.count)
        #expect(Set(allFromGroups) == Set(HapticType.allCases))
    }

    @Test("groupedOptions has 4 groups in correct order")
    func groupedOptionsOrder() {
        let categories = HapticType.groupedOptions.map { $0.category }
        #expect(categories == [.impact, .selection, .notification, .none])
    }

    @Test("HapticType round-trips through Codable")
    func hapticTypeCodable() throws {
        for type in HapticType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(HapticType.self, from: data)
            #expect(decoded == type)
        }
    }

    // MARK: - HapticZone

    @Test("Zone displayNames are non-empty English strings")
    func zoneDisplayNames() {
        for zone in HapticZone.allCases {
            #expect(!zone.displayName.isEmpty)
        }
        #expect(HapticZone.alphanumeric.displayName == "Alphanumeric")
        #expect(HapticZone.clicky.displayName == "Clicky")
        #expect(HapticZone.tactile.displayName == "Tactile")
        #expect(HapticZone.gestures.displayName == "Gestures")
    }

    @Test("Zone icons are non-empty SF Symbol names")
    func zoneIcons() {
        for zone in HapticZone.allCases {
            #expect(!zone.icon.isEmpty)
        }
    }

    @Test("HapticZone round-trips through Codable")
    func hapticZoneCodable() throws {
        for zone in HapticZone.allCases {
            let data = try JSONEncoder().encode(zone)
            let decoded = try JSONDecoder().decode(HapticZone.self, from: data)
            #expect(decoded == zone)
        }
    }

    // MARK: - Key-to-Zone Mapping

    @Test("Enter maps to clicky zone")
    func enterMapsToClicky() {
        #expect(HapticZone.zone(for: "Enter") == .clicky)
    }

    @Test("Kill maps to clicky zone")
    func killMapsToClicky() {
        #expect(HapticZone.zone(for: "Kill") == .clicky)
    }

    @Test("Tab maps to tactile zone")
    func tabMapsToTactile() {
        #expect(HapticZone.zone(for: "Tab") == .tactile)
    }

    @Test("Arrow keys map to tactile zone")
    func arrowsMapsToTactile() {
        #expect(HapticZone.zone(for: "\u{2191}") == .tactile)
        #expect(HapticZone.zone(for: "\u{2193}") == .tactile)
        #expect(HapticZone.zone(for: "\u{2190}") == .tactile)
        #expect(HapticZone.zone(for: "\u{2192}") == .tactile)
    }

    @Test("Ctrl and Alt map to tactile zone")
    func modifiersMapsToTactile() {
        #expect(HapticZone.zone(for: "Ctrl") == .tactile)
        #expect(HapticZone.zone(for: "Alt") == .tactile)
    }

    @Test("S-Tab and / map to tactile zone")
    func shortcutBarKeysMapsToTactile() {
        #expect(HapticZone.zone(for: "S-Tab") == .tactile)
        #expect(HapticZone.zone(for: "/") == .tactile)
        #expect(HapticZone.zone(for: "scrollTmux") == .tactile)
    }

    @Test("paneSwipe maps to gestures zone")
    func paneSwipeMapsToGestures() {
        #expect(HapticZone.zone(for: "paneSwipe") == .gestures)
    }

    @Test("No key maps to alphanumeric zone (it uses onSoftKeyboardInput)")
    func noKeyMapsToAlphanumeric() {
        for (_, zone) in HapticZone.keyZoneMap {
            #expect(zone != .alphanumeric)
        }
    }

    @Test("Unknown key returns nil")
    func unknownKeyReturnsNil() {
        #expect(HapticZone.zone(for: "nonexistent") == nil)
    }

    @Test("Every key bar item label has a zone mapping")
    func allKeyBarItemsMapped() {
        let keyBarLabels = ["S-Tab", "/", "Tab", "Esc",
                            "\u{2191}", "\u{2193}", "\u{2190}", "\u{2192}",
                            "Ctrl", "Alt", "Kill", "Enter"]
        for label in keyBarLabels {
            #expect(HapticZone.zone(for: label) != nil, "Missing zone for key: \(label)")
        }
    }
}
