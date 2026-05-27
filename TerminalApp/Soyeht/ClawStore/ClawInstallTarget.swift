import Foundation

/// UI-facing target for a Claw Store flow on iOS. Carries a `Server.ID` —
/// the only identity the user mental-models as "where this claw lives".
///
/// PR-3 introduces this type so the iOS Claw Store stops speaking the
/// dual `ClawAPITarget.server(_)` / `ClawAPITarget.household` vocabulary
/// at the View/route layer. Every iOS entry point (the Home Claw Store
/// button, the server picker, the catalog rows) hands one of these to
/// the resolver, which decides the concrete wire path.
///
/// `Server.ID` is `String` (the unified registry id); using a typealias
/// here would obscure the model boundary, so the field name carries the
/// semantics instead.
struct ClawInstallTarget: Hashable, Sendable {
    /// Server identifier as exposed by `ServerRegistry.shared.servers`.
    /// For Macs this is the lowercased `macID` UUID string; for Linux
    /// hosts this is the `PairedServer.id`. Both shapes are stable and
    /// match what `SessionStore.context(for:)` accepts.
    let serverID: String

    init(serverID: String) {
        self.serverID = serverID
    }
}
