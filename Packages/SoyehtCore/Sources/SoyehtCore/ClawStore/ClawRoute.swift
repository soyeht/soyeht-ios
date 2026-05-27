import Foundation

/// Navigation route inside the Claw Store (iOS NavigationStack / macOS
/// NavigationSplitView). Cases carry the model and server id so the current
/// stack entry can resolve the same server after SwiftUI rebuilds the root
/// view; the session token stays in `SessionStore`, not in the path.
public enum ClawRoute: Hashable {
    case store(serverId: String)
    case householdStore
    /// Associated value is `Claw`, but `Claw.==` compares only by `name`
    /// (see ClawModels.swift). That is intentional: it keeps `NavigationPath`
    /// stable across poll ticks that only mutate `installState`/availability,
    /// so the detail view is not re-created on every refresh. Tests that
    /// compare `Claw` values should not rely on `==` catching state drift.
    case detail(Claw, serverId: String)
    case householdDetail(Claw)
    case setup(Claw, serverId: String)
    /// Pushed by iOS when the home Claw Store button is tapped while
    /// `ServerRegistry.shared.count >= 2`. The picker view enumerates
    /// every paired server and routes the user to a `.store(serverId:)`
    /// for the one they tap. Macs that the resolver can't route to
    /// directly render disabled in the picker — see PR-3 docs at
    /// `docs/claw-install-target.md`.
    ///
    /// macOS does not produce this case today; the Mac Claw Store root
    /// view handles it with an explicit `EmptyView()` ramp to keep the
    /// `ClawRoute` switch exhaustive.
    case serverPicker
}
