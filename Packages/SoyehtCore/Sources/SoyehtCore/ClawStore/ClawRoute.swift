import Foundation

/// Navigation route inside the Claw Store (iOS NavigationStack / macOS
/// NavigationSplitView). Cases carry the model and server id so the current
/// stack entry can resolve the same server after SwiftUI rebuilds the root
/// view; the session token stays in `SessionStore`, not in the path.
public enum ClawRoute: Hashable {
    case store(serverId: String)
    /// Associated value is `Claw`, but `Claw.==` compares only by `name`
    /// (see ClawModels.swift). That is intentional: it keeps `NavigationPath`
    /// stable across poll ticks that only mutate `installState`/availability,
    /// so the detail view is not re-created on every refresh. Tests that
    /// compare `Claw` values should not rely on `==` catching state drift.
    case detail(Claw, serverId: String)
    case setup(Claw, serverId: String)
}
