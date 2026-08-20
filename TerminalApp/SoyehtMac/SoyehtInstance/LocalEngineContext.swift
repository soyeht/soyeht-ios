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
    /// Why resolution failed, when it did.
    ///
    /// MEASURED on a cold boot, 2026-08-20: the app started at 11:27:08 and
    /// asked for the engine at 11:27:14; launchd did not start the engine
    /// until 11:27:45 — **31 seconds later**. `resolve()` could only say
    /// "nil", the caller read that as permanent, and every restored pane fell
    /// back to an in-process PTY and stayed fragile for the whole session.
    ///
    /// The distinction this carries is the whole fix: "nothing answered yet"
    /// is worth waiting for, "there is nothing to answer with" is not.
    enum Resolution {
        case resolved(ServerContext)
        /// Nothing answered on the loopback admin port. The engine is a
        /// launchd job with `RunAtLoad`, so at login it is coming — just not
        /// yet.
        case engineNotAnsweringYet
        /// The engine answered and could not pair us, or there is no context
        /// to build. Waiting changes nothing.
        case unavailable
    }

    /// Transport-level codes that mean "nothing answered", as opposed to
    /// "answered and refused". Mirrors `MacOSWebSocketTerminalView`'s set and
    /// `EnginePaneAttacher`'s, so the app has one vocabulary for this.
    static let notAnsweringURLErrorCodes: Set<Int> = [-1001, -1004, -1005, -1009]

    /// - Returns: `true` when the failure means nothing answered yet.
    ///   `Could not connect to the server` (-1004) is the one measured on a
    ///   cold boot.
    static func isNotAnsweringYet(_ error: Error) -> Bool {
        notAnsweringURLErrorCodes.contains((error as NSError).code)
    }

    static func resolveDetailed(
        store: SessionStore = .shared,
        autoPair: () async throws -> PairedServer = { try await TheyOSAutoPairService().autoPair() }
    ) async -> Resolution {
        let localHost = SoyehtInstallProfile.current.adminHost
        if let existing = store.pairedServers.first(where: { $0.kind == .engine && $0.host == localHost }),
           let context = store.context(for: existing.id) {
            return .resolved(context)
        }
        do {
            let paired = try await autoPair()
            guard let context = store.context(for: paired.id) else { return .unavailable }
            return .resolved(pinnedToLocalHost(context, localHost: localHost))
        } catch {
            logger.error("local engine self-pair failed: \(error.localizedDescription, privacy: .public)")
            return isNotAnsweringYet(error) ? .engineNotAnsweringYet : .unavailable
        }
    }

    static func resolve(
        store: SessionStore = .shared,
        autoPair: () async throws -> PairedServer = { try await TheyOSAutoPairService().autoPair() }
    ) async -> ServerContext? {
        if case .resolved(let context) = await resolveDetailed(store: store, autoPair: autoPair) {
            return context
        }
        return nil
    }

    /// The real self-pair (`TheyOSAutoPairService`) records this Mac's engine
    /// row under its externally reachable hostname (e.g. its tailnet DNS
    /// name) so the same row also serves remote flows — which means the
    /// `host == adminHost` match above almost never fires on a real install
    /// and resolution falls through to `autoPair()`. Following that row's
    /// host verbatim sends every local-terminal call to the machine's public
    /// surface, where a DIFFERENT engine instance (e.g. the shipping one,
    /// which may not even have these routes — the live symptom was HTTP 405
    /// from its SPA fallback, then a permanent `NativePTY` downgrade)
    /// answers instead of this profile's own loopback engine. The row's
    /// token is minted by this same engine and is host-independent, so pin
    /// the transport to the loopback admin host and keep the credential.
    private static func pinnedToLocalHost(_ context: ServerContext, localHost: String) -> ServerContext {
        guard context.host != localHost else { return context }
        let s = context.server
        let pinned = PairedServer(
            id: s.id,
            host: localHost,
            name: s.name,
            role: s.role,
            pairedAt: s.pairedAt,
            expiresAt: s.expiresAt,
            platform: s.platform,
            kind: s.kind,
            engineMachineId: s.engineMachineId
        )
        return ServerContext(server: pinned, token: context.token)
    }
}
