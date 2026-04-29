import Foundation

/// Filesystem locations + network endpoints owned by the local theyOS
/// install. Centralized so every service (installer, prober, auto-pair)
/// sees the same set of paths.
///
/// Matches the layout described in `~/Documents/theyos`
/// (Homebrew formula + `launcher-rs`): `~/.theyos/.env`,
/// `~/.theyos/bootstrap-token`, admin backend on `localhost:8892`.
enum TheyOSEnvironment {

    /// `~/.theyos/`
    static var rootDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".theyos", isDirectory: true)
    }

    /// `~/.theyos/.env` — contains `SOYEHT_ADMIN_PASSWORD` + `THEYOS_SESSION_PEPPER`.
    static var envFile: URL {
        rootDir.appendingPathComponent(".env")
    }

    /// `~/.theyos/bootstrap-token` — Bearer token accepted by the admin API
    /// until a real admin session exists.
    static var bootstrapTokenFile: URL {
        rootDir.appendingPathComponent("bootstrap-token")
    }

    /// Admin backend URL on localhost (matches `ADMIN_PORT=8892` default).
    static var adminHost: String { "localhost:8892" }
    static var healthURL: URL { URL(string: "http://\(adminHost)/health")! }

    /// Candidate Homebrew binary locations. Apple Silicon puts it under
    /// `/opt/homebrew`; Intel Macs use `/usr/local`. We iterate both so the
    /// installer works on either host without hard-coding.
    static let brewBinaryCandidates: [String] = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// First brew binary that exists on disk, or `nil` if Homebrew is not
    /// installed. Checked up-front so the UI can present a download link
    /// before attempting to spawn a missing process.
    static func locateBrewBinary() -> String? {
        let fm = FileManager.default
        return brewBinaryCandidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    /// Whether a theyOS install already exists on this Mac. Used by the
    /// Welcome flow to detect repeat-install scenarios — when a paired
    /// session was wiped (or never created) but the brew formula is still
    /// present, running the full install pipeline on top of itself
    /// produces friction (untap fails, brew install no-ops, soyeht start
    /// races a possibly-running server). The Welcome flow uses this to
    /// surface a "Reuse / Reinstall" prompt instead.
    ///
    /// We check both the Cellar (authoritative install dir) and the `opt`
    /// symlink (survives a partial uninstall that left a dangling link).
    /// Either is sufficient evidence that brew has theyos staged.
    static func isTheyOSInstalled() -> Bool {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/Cellar/theyos",
            "/usr/local/Cellar/theyos",
            "/opt/homebrew/opt/theyos",
            "/usr/local/opt/theyos",
        ]
        // `attributesOfItem(atPath:)` uses lstat so a dangling symlink at
        // `opt/theyos` (left by a partial uninstall) still counts as
        // present — exactly what we want, since it implies the user is
        // recovering and a fresh reinstall will repair the link.
        return candidates.contains { path in
            (try? fm.attributesOfItem(atPath: path)) != nil
        }
    }

    /// Whether a Tailscale daemon is plausibly available. The launcher does
    /// the real detection (via `tailscale status --json`); this lightweight
    /// check just drives UI copy ("Tailscale detected" vs. "install Tailscale
    /// first").
    static func isTailscaleInstalled() -> Bool {
        let fm = FileManager.default
        let paths = [
            "/Applications/Tailscale.app",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        return paths.contains(where: { fm.fileExists(atPath: $0) })
    }

    /// Read the admin password from `~/.theyos/.env`. Returns `nil` when the
    /// install hasn't produced the file yet.
    static func readAdminPassword() -> String? {
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "SOYEHT_ADMIN_PASSWORD="
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Read the bootstrap token (trimmed) from
    /// `~/.theyos/bootstrap-token`. Returns `nil` until theyOS has been
    /// started at least once.
    static func readBootstrapToken() -> String? {
        guard let contents = try? String(contentsOf: bootstrapTokenFile, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Probe the installed `soyeht` CLI to see if `start` accepts
    /// `--network`. Runs `soyeht start --help` and greps the output. Users
    /// on older taps (before the flag landed) return `false` so the
    /// installer falls back to the default bind instead of sending an arg
    /// the binary will reject. Times out after 5s to avoid blocking the UI
    /// if the CLI misbehaves.
    static func cliSupportsNetworkFlag(binary: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["start", "--help"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: text.contains("--network"))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }
            // Defensive kill if the CLI hangs printing --help.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
