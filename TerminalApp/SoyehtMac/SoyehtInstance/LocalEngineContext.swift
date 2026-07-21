import Foundation
import SoyehtCore
import os

/// Resolves the `ServerContext` for THIS Mac's own embedded `theyos` engine —
/// distinct from `SessionStore.activeServer`, which tracks whichever server
/// (possibly a remote Mac/Linux instance) the UI currently has selected.
///
/// Persistent local panes must always target this Mac's own engine: spawning
/// `argv` is host code execution on whichever machine `context.host` names,
/// so silently following "whichever server the UI has active" would execute
/// on a REMOTE machine the moment the user had a remote instance selected.
/// `SessionStore.pairedServers` has no dedicated marker for "this Mac's own
/// engine" — it is just another `.engine`-kind row, indistinguishable from a
/// *different* Mac's engine paired remotely — so this resolver matches on
/// `host` against `SoyehtInstallProfile.current.adminHost` instead.
@MainActor
enum LocalEngineContext {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "local-engine-context")

    /// Finds the paired-server row for this Mac's own engine and returns its
    /// context. Self-pairs on demand (mirroring `TheyOSAutoPairService`, the
    /// same flow `WelcomeRootView`/`LocalInstallView` run at onboarding) if
    /// no session exists yet — some onboarding paths skip local self-pair
    /// when a remote server is paired first. Returns `nil` if self-pairing
    /// also fails (e.g. the one-time bootstrap token was already consumed);
    /// callers should fall back to `NativePTY` rather than block the pane.
    static func resolve(
        store: SessionStore = .shared,
        autoPair: () async throws -> PairedServer = { try await TheyOSAutoPairService().autoPair() }
    ) async -> ServerContext? {
        let localHost = SoyehtInstallProfile.current.adminHost
        if let existing = store.pairedServers.first(where: { $0.kind == .engine && $0.host == localHost }),
           let context = store.context(for: existing.id) {
            return context
        }
        do {
            let paired = try await autoPair()
            return store.context(for: paired.id)
        } catch {
            logger.error("local engine self-pair failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
