import Foundation
import Testing

@testable import SoyehtCore

/// Fase 2 PR1 guard for the inert `OnboardingConfig` single source of truth.
///
/// Pins that the defaults equal the values currently hard-coded at each
/// onboarding site (so a later migration to `.default` is behavior-preserving)
/// and that timeout validation rejects non-positive durations.
@Suite struct OnboardingConfigTests {
    @Test func defaultMatchesCurrentOnboardingSites() {
        let config = OnboardingConfig.default
        // Must equal the live constants on main (see each property's doc):
        #expect(config.houseNamingHintDelay == 5)            // HouseNamingFromiPhoneView.slowHintDelay
        #expect(config.macDiscoveryDeadline == 60)           // AwaitingMacView deadline
        #expect(config.macDiscoveryRecoveryHintDelay == 20)  // AwaitingMacView.recoveryHintDelaySeconds
        #expect(config.macProbeTimeout == 2)                 // AwaitingMacView probe timeoutInterval
        #expect(config.householdDiscoveryTimeout == 10)      // HouseholdPairingService firstMatchingCandidate
    }

    @Test func defaultPassesValidation() throws {
        try OnboardingConfig.default.validate()
    }

    @Test func zeroTimeoutFailsValidationWithField() {
        let bad = OnboardingConfig(macDiscoveryDeadline: 0)
        #expect(throws: OnboardingConfig.ValidationError.nonPositive(field: "macDiscoveryDeadline", value: 0)) {
            try bad.validate()
        }
    }

    @Test func negativeTimeoutFailsValidation() {
        let bad = OnboardingConfig(houseNamingHintDelay: -1)
        #expect(throws: OnboardingConfig.ValidationError.self) {
            try bad.validate()
        }
    }

    @Test func customValuesArePreservedAndEquatable() {
        let custom = OnboardingConfig(houseNamingHintDelay: 7, macDiscoveryDeadline: 90)
        #expect(custom.houseNamingHintDelay == 7)
        #expect(custom.macDiscoveryDeadline == 90)
        // Untouched fields keep their defaults.
        #expect(custom.householdDiscoveryTimeout == 10)
        #expect(custom != OnboardingConfig.default)
        #expect(custom == OnboardingConfig(houseNamingHintDelay: 7, macDiscoveryDeadline: 90))
    }
}
