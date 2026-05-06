import Foundation

/// Resolves the on-disk base directory for SoyehtMac's persisted state.
///
/// Replaces two legacy patterns that previously sat at every storage call
/// site:
///
///   1. `(try? appSupportURL) ?? URL(fileURLWithPath: NSTemporaryDirectory())`
///      — workspace state, automation state. The fallback wrote user data
///      into the system scratch dir, where the OS reaps files under disk
///      pressure or on restart. Users would silently lose their saved
///      workspaces / automation runs.
///   2. `URL(fileURLWithPath: "/tmp/soyeht-…")` — debug benchmark output,
///      handoff dumps, voice input log. Hard-coded `/tmp` is technically
///      world-readable on a multi-user macOS install (file mode aside,
///      `/tmp` is symlinked to `/private/tmp` and other apps can list
///      directory entries) and gets purged unpredictably.
///
/// Both shapes route through here now, anchored under
/// `~/Library/Application Support/Soyeht/`. The throwing variant of
/// `FileManager.url(for:in:appropriateFor:create:)` only fails when
/// `create: true` is requested against an unwritable disk — at that
/// point we cannot persist anywhere safely and crashing loudly is the
/// correct response.
enum AppSupportDirectory {

    /// Soyeht's root: `~/Library/Application Support/Soyeht/`.
    /// Created on first call; subsequent calls return the existing dir.
    static func soyehtRoot() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport.appendingPathComponent("Soyeht", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    /// Subdirectory of `Soyeht/`. Created if absent.
    /// Conventional names in use: `Automation`, `Debug`.
    static func subdirectory(_ name: String) throws -> URL {
        let dir = try soyehtRoot().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    /// Soyeht/Debug — DEBUG-only dumps that previously lived in `/tmp`.
    /// Trapping on failure rather than falling back: a Debug build that
    /// cannot reach Application Support is a development environment
    /// problem, not something to paper over with a temp-dir fallback.
    static func debugDirectory() -> URL {
        do {
            return try subdirectory("Debug")
        } catch {
            preconditionFailure(
                "Cannot create Application Support / Soyeht / Debug directory: \(error)"
            )
        }
    }
}
