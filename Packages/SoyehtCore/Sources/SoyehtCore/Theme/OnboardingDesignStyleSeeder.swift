import Foundation

/// A brand new install wakes up in the style setup just showed it.
///
/// `DesignStyle.active` returns classic whenever nothing is persisted, so
/// every first launch landed in the old chrome moments after walking through
/// a setup drawn in Neo Milk. The two looked like different apps.
///
/// The one rule this must never break: it only ever writes when nobody has
/// chosen anything. A sentinel records that the decision was made, so an
/// existing owner — including one who deliberately runs classic — is never
/// flipped by an update.
public enum OnboardingDesignStyleSeeder {
    public static let sentinelKey = "soyeht.appearance.firstLaunchApplied"
    public static let seededThemeID = "neoMilk"

    /// The whole decision, with the world passed in. Kept separate from the
    /// write so it can be tested without a machine that has opinions.
    public static func shouldSeed(
        sentinelAlreadyWritten: Bool,
        isSetUp: Bool,
        hasChosenStyle: Bool
    ) -> Bool {
        guard !sentinelAlreadyWritten else { return false }
        // A machine that already has a household or a paired server has been
        // used before; its appearance is its own.
        guard !isSetUp else { return false }
        return !hasChosenStyle
    }

    @discardableResult
    public static func seedIfNeverChosen(
        isSetUp: Bool,
        preferences: TerminalPreferences = .shared,
        themes: TerminalThemeStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let sentinelWritten = defaults.bool(forKey: sentinelKey)
        // Written whatever the answer: this question is asked once per
        // install, never again.
        defaults.set(true, forKey: sentinelKey)

        guard shouldSeed(
            sentinelAlreadyWritten: sentinelWritten,
            isSetUp: isSetUp,
            hasChosenStyle: preferences.designStyleRaw != nil
        ) else { return false }

        guard let milk = themes.allThemes().first(where: { $0.id == seededThemeID }),
              DesignStyle.neomorphic.canWear(milk),
              DesignStyle.available.contains(.neomorphic) else {
            return false
        }

        themes.setActiveTheme(id: seededThemeID)
        DesignStyle.setActive(.neomorphic)
        return true
    }
}
