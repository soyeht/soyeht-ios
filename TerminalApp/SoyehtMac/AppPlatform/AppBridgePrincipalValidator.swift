import Foundation

/// Why a bridge message was refused BEFORE dispatch. Case order matches the
/// contractual validation order (docs/capability-bridge-phase2b.md §2) —
/// the raw value is audit-safe vocabulary (no origin, no path, no host).
enum AppBridgePrincipalRefusal: String, Equatable {
    /// Step 1: the message's world is not the bridge world.
    case wrongWorld = "wrong_world"
    /// Step 2: the sender is not the main frame. Load-bearing because
    /// about:blank/srcdoc subframes INHERIT the parent's origin and pass
    /// any origin comparison — only frame identity stops them.
    case subframe = "subframe"
    /// Step 3: the observed origin's exact (scheme, host, port) triple
    /// differs from the pane's own origin. Never a prefix comparison —
    /// prefixes match `exemplo.com.atacante.com`.
    case foreignOrigin = "foreign_origin"
    /// Step 4: the origin's host is empty. Subsumed by step 3 while the
    /// expected host is non-empty; kept as its own step so the contract
    /// order survives a future empty expected host.
    case emptyHost = "empty_host"
}

/// Principal validation for the capability bridge, extracted as a pure,
/// WebKit-free function (kairos's construction upgrade): synthetic fixtures
/// exercise subframe, foreign origin, and empty host in the domain package,
/// because the E2E cannot — the 2a CSP declares no frame-src, so subframes
/// never load at all (measured: the acceptance iframe stayed empty, blocked
/// by `default-src 'none'` fallback, NOT by the navigation lock).
///
/// ORDER IS THE CONTRACT: a message failing two checks must be refused for
/// the FIRST reason. The order is what closes confused-deputy paths, and
/// only these tests pin it against an "innocent" future reordering.
enum AppBridgePrincipalValidator {
    /// The named content world the bridge lives in. Single source of truth —
    /// the handler reads it from here so domain tests never need WebKit.
    static let worldName = "soyeht-bridge"

    static func firstRefusal(
        worldName: String?,
        isMainFrame: Bool,
        scheme: String,
        host: String,
        port: Int,
        expectedWorldName: String,
        expectedScheme: String,
        expectedHost: String
    ) -> AppBridgePrincipalRefusal? {
        guard worldName == expectedWorldName else { return .wrongWorld }
        guard isMainFrame else { return .subframe }
        guard scheme == expectedScheme, host == expectedHost, port == 0 else { return .foreignOrigin }
        guard !host.isEmpty else { return .emptyHost }
        return nil
    }
}
