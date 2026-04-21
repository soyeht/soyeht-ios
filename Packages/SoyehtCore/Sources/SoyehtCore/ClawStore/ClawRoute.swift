import Foundation

/// Navigation route inside the Claw Store (iOS NavigationStack / macOS
/// NavigationSplitView). Cases carry the model so the current stack entry
/// can be reconstructed after a deep link or state restoration.
public enum ClawRoute: Hashable {
    case store
    /// Associated value is `Claw`, but `Claw.==` compares only by `name`
    /// (see ClawModels.swift). That is intentional: it keeps `NavigationPath`
    /// stable across poll ticks that only mutate `installState`/availability,
    /// so the detail view is not re-created on every refresh. Tests that
    /// compare `Claw` values should not rely on `==` catching state drift.
    case detail(Claw)
    case setup(Claw)
}
