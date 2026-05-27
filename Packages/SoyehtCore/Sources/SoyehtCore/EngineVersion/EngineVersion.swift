import Foundation

/// Engine semver compatibility gate.
///
/// The iOS Soyeht client and the theyos engine evolve in lockstep but live
/// in separate repos. When the client starts depending on a new engine
/// endpoint (e.g. a route added in `theyos` after the previous release),
/// older engines respond with 404 / wrong Content-Type / missing fields and
/// the user sees opaque protocol-violation errors deep in the flow.
///
/// `EngineCompat` is the single gate that prevents that: bootstrap clients
/// fetch `/bootstrap/status` first, read `engineVersion` (semver string —
/// **not** the envelope `version: UInt64`!), and refuse to proceed when the
/// engine is older than `minSupportedEngineVersion`. The user sees a clear
/// "update Soyeht on this Mac" message instead of a generic decode error.
///
/// Bump `minSupportedEngineVersion` whenever the iOS client starts requiring
/// a route or wire format that an older engine cannot satisfy. The companion
/// bump in `scripts/theyos-engine.version` ships the matching engine binary
/// inside the next Soyeht.app DMG. See `docs/engine-protocol-version.md`.
public enum EngineCompat {
    /// Minimum semver of theyos engine this iOS client speaks against.
    ///
    /// **Bump rule**: increment whenever the iOS client begins calling an
    /// endpoint or expecting a wire field that the previous engine version
    /// did not have. The matching engine release tag must already be on
    /// GitHub (`soyeht/theyos` releases) before bumping here, and
    /// `scripts/theyos-engine.version` should land in the same commit.
    ///
    /// Set to `"0.1.19"` as the **minimum functional** version, not
    /// just the minimum protocol version:
    ///
    ///   - `0.1.17` shipped the household-namespaced Claw Store routes
    ///     (`/api/v1/household/claws*`) that this iOS client depends
    ///     on, so the protocol floor would be `0.1.17` alone.
    ///   - **But** `0.1.17` also shipped a regression that crashes the
    ///     very first Claw install attempt on a fresh engine with
    ///     `failed to mark installing: IO error: No such file or
    ///     directory (os error 2)` — `ClawStore::persist()` did not
    ///     create the parent of its state file. `0.1.18` is the first
    ///     engine version where the household Claw Store routes
    ///     actually work end-to-end on a clean install.
    ///   - `0.1.19` adds the pair-machine local staging route used by
    ///     the Mac "Join existing Soyeht" flow and the `guest_image_*`
    ///     status fields consumed by the iOS Claw install gate. This
    ///     app release bundles `0.1.19`, so the pre-flight floor should
    ///     match the engine surface the UI now speaks.
    ///
    /// Bumping the compat floor here forces users of a Mac running an
    /// older engine to upgrade SoyehtMac before pairing — which is the
    /// right policy when "older" includes a known-broken release.
    public static let minSupportedEngineVersion = "0.1.19"

    /// Returns `true` when `engineVersion` (a semver-shaped string like
    /// `"0.1.17"` or `"1.2.3-rc.1"`) is greater than or equal to
    /// `minSupportedEngineVersion`. Unparseable strings (e.g. `"unknown"`,
    /// missing dots, non-numeric components) are treated as incompatible —
    /// we refuse to talk to engines we cannot identify.
    public static func isCompatible(_ engineVersion: String) -> Bool {
        compareSemver(engineVersion, minSupportedEngineVersion) != .orderedAscending
    }

    /// Compares two semver strings by their numeric `MAJOR.MINOR.PATCH`
    /// components. Pre-release / build suffixes (anything after the first
    /// `-` or `+`) are stripped before comparison: `"0.1.17-rc.1"` compares
    /// equal to `"0.1.17"`. Returns `.orderedSame` when either string is
    /// unparseable on the other side — but `parseSemver` returning `nil`
    /// short-circuits to `.orderedAscending` so unknown versions are
    /// treated as "older than required" (callers refuse them).
    public static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let l = parseSemver(lhs) else { return .orderedAscending }
        guard let r = parseSemver(rhs) else { return .orderedDescending }
        for (a, b) in zip(l, r) {
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Parses `MAJOR.MINOR.PATCH` into a 3-element `[UInt64]`, stripping
    /// pre-release / build metadata. Returns `nil` for any other shape.
    static func parseSemver(_ string: String) -> [UInt64]? {
        // Drop pre-release / build metadata.
        let core = string.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        let parts = core.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let parsed = parts.compactMap { UInt64($0) }
        guard parsed.count == 3 else { return nil }
        return parsed
    }

    /// Pre-flight handshake: fetches `/bootstrap/status` and throws
    /// `BootstrapError.engineTooOld` if the engine's semver is below
    /// `minSupportedEngineVersion`. Every mutating bootstrap call
    /// (`BootstrapInitializeClient.initialize`,
    /// `BootstrapAcceptHouseholdClient.accept`) routes through this gate
    /// so the user gets a clear "update Soyeht on this Mac" message
    /// instead of an opaque protocol-violation error deep in the flow.
    ///
    /// If `/bootstrap/status` itself fails (network drop, decode error),
    /// that error propagates unchanged — the precheck never masks the
    /// original failure with a misleading version error.
    public static func assertCompatible(via statusClient: BootstrapStatusClient) async throws {
        let status = try await statusClient.fetch()
        guard isCompatible(status.engineVersion) else {
            throw BootstrapError.engineTooOld(
                found: status.engineVersion,
                required: minSupportedEngineVersion
            )
        }
    }
}
