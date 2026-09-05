import Foundation

/// E3 (mini): resolves the active Mac Claw Store target's `ServerContext` from the
/// CANONICAL inventory (the Track-D `ServerStore` SSOT) for metadata, using
/// `SessionStore` only as the credential lookup.
///
/// This replaces `SessionStore.currentContext()` on the Mac Claw Store path, which
/// sources server metadata from the legacy `pairedServers` view and can drift from
/// the canonical row after the ServerStore migration. macOS does not have the
/// iOS resolver's household-endpoint / unavailable / server-picker axes, so the
/// useful slice is narrow: read the canonical row + the credential, never wrap the
/// legacy store for metadata.
///
/// Returns nil if there is no active server, no canonical row for it, or no token —
/// the same "nothing actionable" contract `currentContext()` had.
public enum MacActiveServerContextResolver {
    /// Where `LocalEngineContext` (app side) records which canonical row is this
    /// Mac's own engine, after it verified the row's credential on loopback.
    /// Read here rather than passed in, because every call site on this path
    /// calls `activeContext()` with no arguments.
    static let verifiedLocalEngineServerIDKey = "verifiedLocalEngineServerID"

    public static func activeContext(sessionStore: SessionStore = .shared) -> ServerContext? {
        activeContext(
            sessionStore: sessionStore,
            defaults: .standard,
            localAdminHost: SoyehtInstallProfile.current.adminHost
        )
    }

    static func activeContext(
        sessionStore: SessionStore,
        defaults: UserDefaults,
        localAdminHost: String
    ) -> ServerContext? {
        guard let activeID = sessionStore.activeServerId else { return nil }
        guard let canonical = sessionStore.canonicalServers().first(where: { $0.id == activeID }) else {
            return nil
        }
        // `context(for: Server)` uses the CANONICAL row's metadata + the credential;
        // nil if the token was evicted.
        guard let context = sessionStore.context(for: canonical) else { return nil }
        return pinnedToLoopbackIfLocalEngine(
            context,
            defaults: defaults,
            localAdminHost: localAdminHost
        )
    }

    /// This Mac's own engine row is stored under the host the engine reports as
    /// best for a QR (`best_qr_host()` — tailnet name, or the LAN address), so
    /// that the same row also serves a phone. The admin API it exposes is bound
    /// to loopback ONLY, so following that host verbatim from this machine dials
    /// an address where nothing listens.
    ///
    /// MEASURED 2026-09-04: every pane opened refreshed the Claw Store through
    /// this resolver, dialled `192.168.15.2:8892` — this Mac's own LAN address —
    /// and got ECONNREFUSED, twelve `-1004` lines per pane (`/api/v1/mobile/claws`
    /// and `/instances`, each with three retries). 713 of them in a day.
    ///
    /// The terminal paths already cure this by pinning the transport to the
    /// loopback admin host (`LocalEngineContext.pinnedToLocalHost`); the Claw
    /// Store path never did. The token is minted by that same engine and is
    /// host-independent, so pinning keeps the credential valid.
    ///
    /// Only the row the app itself verified on loopback is pinned: a remote
    /// engine (a Linux box, another Mac over the tailnet) keeps its host.
    private static func pinnedToLoopbackIfLocalEngine(
        _ context: ServerContext,
        defaults: UserDefaults,
        localAdminHost: String
    ) -> ServerContext {
        guard context.server.kind == .engine,
              defaults.string(forKey: verifiedLocalEngineServerIDKey) == context.server.id,
              context.server.host != localAdminHost else {
            return context
        }
        let s = context.server
        let pinned = PairedServer(
            id: s.id,
            host: localAdminHost,
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
