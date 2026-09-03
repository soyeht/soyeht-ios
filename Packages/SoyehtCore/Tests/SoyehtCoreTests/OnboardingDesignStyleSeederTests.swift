import Foundation
import Testing
@testable import SoyehtCore

/// Seeding appearance is a one-time, first-launch-only write. The dangerous
/// failure is not "the new install looks old" — it is "an existing owner's
/// choice was overwritten by an update", so most of these guard that.
@Suite("OnboardingDesignStyleSeeder")
struct OnboardingDesignStyleSeederTests {
    @Test func aBrandNewInstallIsSeeded() {
        #expect(OnboardingDesignStyleSeeder.shouldSeed(
            sentinelAlreadyWritten: false,
            isSetUp: false,
            hasChosenStyle: false
        ))
    }

    @Test func anOwnerWhoAlreadyPickedAStyleIsNeverOverwritten() {
        #expect(!OnboardingDesignStyleSeeder.shouldSeed(
            sentinelAlreadyWritten: false,
            isSetUp: false,
            hasChosenStyle: true
        ))
    }

    @Test func aMachineThatIsAlreadySetUpIsLeftAlone() {
        #expect(!OnboardingDesignStyleSeeder.shouldSeed(
            sentinelAlreadyWritten: false,
            isSetUp: true,
            hasChosenStyle: false
        ))
    }

    @Test func theQuestionIsAskedOncePerInstall() {
        #expect(!OnboardingDesignStyleSeeder.shouldSeed(
            sentinelAlreadyWritten: true,
            isSetUp: false,
            hasChosenStyle: false
        ))
    }

    @Test func theSentinelIsWrittenEvenWhenNothingIsSeeded() {
        let suite = "com.soyeht.core.tests.seeder.sentinel"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!

        _ = OnboardingDesignStyleSeeder.seedIfNeverChosen(isSetUp: true, defaults: defaults)

        #expect(
            defaults.bool(forKey: OnboardingDesignStyleSeeder.sentinelKey),
            "otherwise every launch would re-ask, and one day the answer would differ"
        )
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test func theStyleItSeedsCanActuallyWearTheThemeItSeeds() throws {
        let milk = try #require(
            TerminalThemeStore.shared.allThemes()
                .first { $0.id == OnboardingDesignStyleSeeder.seededThemeID }
        )
        #expect(DesignStyle.neomorphic.canWear(milk))
        #expect(DesignStyle.available.contains(.neomorphic))
    }
}
