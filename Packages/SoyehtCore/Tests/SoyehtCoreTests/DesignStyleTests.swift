import Foundation
import Testing
@testable import SoyehtCore

@Suite("DesignStyle")
struct DesignStyleTests {
    /// Runs `body` with the persisted design-style raw value replaced by
    /// `raw`, restoring whatever the host machine had afterwards so tests
    /// never leak state into the developer's real preferences.
    private func withStoredRaw(_ raw: String?, _ body: () throws -> Void) rethrows {
        let previous = TerminalPreferences.shared.designStyleRaw
        TerminalPreferences.shared.designStyleRaw = raw
        defer { TerminalPreferences.shared.designStyleRaw = previous }
        try body()
    }

    @Test func classicIsAlwaysAvailable() {
        #expect(DesignStyle.available.contains(.classic))
    }

    @Test func defaultsToClassicWhenUnset() {
        withStoredRaw(nil) {
            #expect(DesignStyle.active == .classic)
        }
    }

    @Test func roundTripsAnAvailableStyle() {
        withStoredRaw(nil) {
            DesignStyle.setActive(.classic)
            #expect(DesignStyle.active == .classic)
        }
    }

    @Test func fallsBackToClassicForUnknownRaw() {
        withStoredRaw("vaporwave") {
            #expect(DesignStyle.active == .classic)
        }
    }

    /// A style that exists in the enum but has not shipped (not in
    /// `available`) must not activate — a downgraded build would otherwise
    /// render chrome for a style it has no implementation of.
    @Test func fallsBackToClassicForUnavailableStyle() {
        for style in DesignStyle.allCases where !DesignStyle.available.contains(style) {
            withStoredRaw(style.rawValue) {
                #expect(DesignStyle.active == .classic)
            }
        }
    }
}
