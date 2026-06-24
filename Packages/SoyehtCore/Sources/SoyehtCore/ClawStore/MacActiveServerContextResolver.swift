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
    public static func activeContext(sessionStore: SessionStore = .shared) -> ServerContext? {
        guard let activeID = sessionStore.activeServerId else { return nil }
        guard let canonical = sessionStore.canonicalServers().first(where: { $0.id == activeID }) else {
            return nil
        }
        // `context(for: Server)` uses the CANONICAL row's metadata + the credential;
        // nil if the token was evicted.
        return sessionStore.context(for: canonical)
    }
}
