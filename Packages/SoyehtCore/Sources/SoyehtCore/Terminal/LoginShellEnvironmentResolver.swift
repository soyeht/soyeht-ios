#if os(macOS)
import Foundation
import os.log

/// Captures the PATH a login interactive shell would produce and exposes it
/// to PTY spawns so non-login bash panes can find user-installed tools.
///
/// Strategy: read disk cache synchronously on warmup, run a `${SHELL} -ilc`
/// probe in the background, write the probe result back to disk for the next
/// launch. Callers check `pathIfReady` (non-blocking) — never block the main
/// thread waiting on the probe.
public final class LoginShellEnvironmentResolver: @unchecked Sendable {

    public static let shared = LoginShellEnvironmentResolver()

    private static let logger = Logger(subsystem: "com.soyeht.core", category: "shell-env")
    static let probeStartMarker = "__SOYEHT_PATH_START__"
    static let probeEndMarker = "__SOYEHT_PATH_END__"
    private static let probeTimeout: TimeInterval = 8
    private static let probeKillGrace: TimeInterval = 0.3
    private static let cacheFileName = "shell-env-path-cache.json"
    private static let cacheFormatVersion = 1
    /// Hard ceiling on cache age. Even when no dotfile mtime fires, we still
    /// re-probe past this age — covers the edge case where a user sources a
    /// secondary script from a dotfile (`source ~/.config/path.sh`) and edits
    /// only the secondary script, leaving the parent dotfile's mtime alone.
    private static let probeStaleCeiling: TimeInterval = 30 * 86400

    private let lock = NSLock()
    private var cached: String?
    private var didStartWarmup = false
    /// `true` once the resolver has either accepted a fresh disk cache or
    /// finished its login probe (success *or* failure). Distinguishes "we
    /// have only the Phase 1 fallback, the probe is still running" from
    /// "this is the best PATH we'll ever have". Async waiters on
    /// `resolvedPath(timeout:)` return as soon as this flips true.
    private var resolutionFinished = false
    private let warmupQueue = DispatchQueue(
        label: "com.soyeht.core.shell-env.warmup",
        qos: .userInitiated
    )

    private init() {}

    /// Idempotent. First caller schedules the resolution; subsequent calls
    /// are no-ops.
    public func warmup() {
        lock.lock()
        let alreadyStarted = didStartWarmup
        didStartWarmup = true
        lock.unlock()
        guard !alreadyStarted else { return }
        warmupQueue.async { [weak self] in
            self?.runResolution()
        }
    }

    /// Non-blocking. `nil` until the disk cache or fallback has been seeded.
    public var pathIfReady: String? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Awaits the resolver's final answer (disk-cached or freshly probed)
    /// without blocking the calling thread. If the resolution doesn't finish
    /// within `timeout`, returns whatever Phase 1 fallback we already have —
    /// best-effort, never `nil` once warmup has run for ~10ms. Safe to call
    /// from the main actor: `Task.sleep` yields between polls so the run
    /// loop keeps spinning.
    public func resolvedPath(timeout: TimeInterval) async -> String? {
        warmup()
        if isResolutionFinished { return pathIfReady }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000) // 25 ms
            if isResolutionFinished { break }
        }
        return pathIfReady
    }

    private var isResolutionFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolutionFinished
    }

    // MARK: - Resolution

    private func runResolution() {
        let currentShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let diskCached = Self.readDiskCache()
        let usingFreshDiskCache: Bool

        if let entry = diskCached, entry.shell == currentShell {
            // Trust the cache iff a) it's younger than the safety ceiling AND
            // b) no shell init file has been edited since the cache was
            // written. Either condition fires → re-probe so the user sees new
            // PATH directories on the very next launch after they edit a
            // dotfile (pyenv install, asdf, manually adding ~/.local/bin, …).
            let stale = Self.cacheIsStale(cacheMtime: entry.cacheMtime, shell: currentShell)
            usingFreshDiskCache = !stale
            lock.lock()
            cached = entry.path
            // A trusted disk cache *is* the final answer — no probe will run,
            // so async waiters can return immediately. Stale caches keep
            // `resolutionFinished` false so awaiters wait for the fresh probe
            // (and only fall back to the stale value after the await timeout).
            if usingFreshDiskCache { resolutionFinished = true }
            lock.unlock()
            Self.logger.info("seeded PATH from disk cache (chars=\(entry.path.count, privacy: .public), stale=\(stale, privacy: .public))")
        } else {
            let fallback = Self.fallbackPath()
            lock.lock()
            cached = fallback
            lock.unlock()
            usingFreshDiskCache = false
            Self.logger.info("seeded PATH from fallback (chars=\(fallback?.count ?? -1, privacy: .public))")
        }

        // Skip the probe if we already trust the disk cache.
        if usingFreshDiskCache { return }

        let probeStarted = Date()
        let probed = Self.probeLoginShellPath(shell: currentShell)
        lock.lock()
        if let probed { cached = probed }
        // Mark resolution finished whether the probe succeeded or failed —
        // failure means the fallback is our final answer, not an interim
        // state, so awaiters shouldn't keep polling for an upgrade.
        resolutionFinished = true
        lock.unlock()
        if let probed {
            Self.writeDiskCache(shell: currentShell, path: probed)
            let elapsedMs = Int(Date().timeIntervalSince(probeStarted) * 1000)
            Self.logger.info("upgraded PATH from login probe in \(elapsedMs, privacy: .public)ms (chars=\(probed.count, privacy: .public))")
        }
    }

    /// Spawns the user's `$SHELL` as a login interactive shell and asks it to
    /// print PATH between two unique markers. Markers shield us from rc-file
    /// banners written to stdout before our printf runs.
    private static func probeLoginShellPath(shell: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            logger.error("SHELL `\(shell, privacy: .public)` is not executable; skipping probe")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", probeScript(forShell: shell)]
        let stdout = Pipe()
        process.standardOutput = stdout
        // Drop stderr. A pipe with no reader fills its kernel buffer (~16 KB)
        // and then blocks the child on its next stderr write — chatty rc
        // files (oh-my-zsh, conda init banners) trigger this and cause the
        // probe to time out unnecessarily.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("PATH probe spawn failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        if waitGroup.wait(timeout: .now() + probeTimeout) == .timedOut {
            // SIGTERM, brief grace, then SIGKILL — guards against shells that
            // trap SIGTERM (e.g. some conda init paths) and would otherwise
            // linger as a zombie until the app exits.
            process.terminate()
            if waitGroup.wait(timeout: .now() + probeKillGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = waitGroup.wait(timeout: .now() + probeKillGrace)
            }
            logger.error("PATH probe timed out after \(probeTimeout, privacy: .public)s")
            return nil
        }

        guard process.terminationStatus == 0 else {
            logger.error("PATH probe exited with status \(process.terminationStatus, privacy: .public)")
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return parseProbeOutput(raw)
    }

    /// Builds the snippet handed to `${SHELL} -ilc`. POSIX shells (bash, zsh,
    /// dash, ksh) get the standard form. Fish treats `$PATH` as a list, so
    /// `"$PATH"` would expand to space-separated entries — we use
    /// `string join` to emit the colon-separated form.
    static func probeScript(forShell shell: String) -> String {
        let basename = (shell as NSString).lastPathComponent
        if basename == "fish" {
            return "printf '\(probeStartMarker)%s\(probeEndMarker)' (string join : $PATH)"
        }
        return "printf '\(probeStartMarker)%s\(probeEndMarker)' \"$PATH\""
    }

    /// Extracts the marker-delimited PATH from probe stdout. Returns nil if
    /// markers are missing or the result doesn't look like a PATH (must
    /// contain a `:` separator — guards against malformed shell output, e.g.
    /// fish without `string join`).
    static func parseProbeOutput(_ raw: String) -> String? {
        guard let start = raw.range(of: probeStartMarker),
              let end = raw.range(of: probeEndMarker, range: start.upperBound..<raw.endIndex) else {
            return nil
        }
        let path = String(raw[start.upperBound..<end.lowerBound])
        guard !path.isEmpty, path.contains(":") else { return nil }
        return path
    }

    /// Last-resort PATH when the login probe fails or hasn't finished yet.
    /// Universal directories only — system paths from `path_helper`, plus
    /// the well-known Homebrew (`/opt/homebrew`, `/usr/local`) and MacPorts
    /// (`/opt/local`) prefixes. Per-user dirs (npm prefix, asdf shims, …)
    /// are intentionally absent: only the login probe can discover those
    /// without bias toward whatever the maintainer happens to have
    /// installed.
    private static func fallbackPath() -> String? {
        var seen = Set<String>()
        var ordered: [String] = []
        let packageManagerPrefixes = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/opt/local/sbin",
        ]
        for dir in packageManagerPrefixes where isDirectory(dir) && seen.insert(dir).inserted {
            ordered.append(dir)
        }
        let helperEntries = pathHelperEntries() ?? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in helperEntries where seen.insert(dir).inserted {
            ordered.append(dir)
        }
        return ordered.isEmpty ? nil : ordered.joined(separator: ":")
    }

    private static func pathHelperEntries() -> [String]? {
        let helper = "/usr/libexec/path_helper"
        guard FileManager.default.isExecutableFile(atPath: helper) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["-s"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        return parsePathHelperOutput(text)
    }

    /// Parses path_helper's `PATH="..."; export PATH;` first line into entries.
    static func parsePathHelperOutput(_ text: String) -> [String]? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("PATH=") }) else {
            return nil
        }
        guard let openQuote = line.firstIndex(of: "\""),
              let closeQuote = line[line.index(after: openQuote)...].firstIndex(of: "\"") else {
            return nil
        }
        let inner = line[line.index(after: openQuote)..<closeQuote]
        let entries = inner.split(separator: ":").map(String.init)
        return entries.isEmpty ? nil : entries
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Staleness detection

    /// `true` when the disk cache should be re-probed. Two triggers:
    ///   1. Cache older than the safety ceiling (`probeStaleCeiling`).
    ///   2. Any shell init file (or `/etc/paths.d/`) has an mtime newer than
    ///      the cache — i.e. the user installed a tool, edited their rc, or
    ///      added/removed a `/etc/paths.d/` entry since we last probed.
    static func cacheIsStale(
        cacheMtime: Date,
        shell: String,
        now: Date = Date(),
        fileSystem: FileSystemProbing = DefaultFileSystem()
    ) -> Bool {
        if now.timeIntervalSince(cacheMtime) > probeStaleCeiling { return true }
        guard let newestDotfile = latestDotfileMtime(forShell: shell, fileSystem: fileSystem) else { return false }
        return newestDotfile > cacheMtime
    }

    /// Newest mtime across every file/dir whose change could affect the
    /// login PATH. Returns nil only if none of the candidates exist (fresh
    /// macOS install with default zsh setup deleted — extremely rare).
    static func latestDotfileMtime(forShell shell: String, fileSystem: FileSystemProbing = DefaultFileSystem()) -> Date? {
        let home = fileSystem.homeDirectoryPath
        var paths: [String] = [
            "\(home)/.zshrc", "\(home)/.zshenv", "\(home)/.zprofile", "\(home)/.zlogin",
            "\(home)/.bashrc", "\(home)/.bash_profile", "\(home)/.bash_login", "\(home)/.profile",
            "/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin",
            "/etc/profile", "/etc/bashrc",
            "/etc/paths",
        ]
        var directoriesToScan: [String] = ["/etc/paths.d"]

        if (shell as NSString).lastPathComponent == "fish" {
            paths.append(contentsOf: [
                "\(home)/.config/fish/config.fish",
                "/etc/fish/config.fish",
            ])
            directoriesToScan.append(contentsOf: [
                "\(home)/.config/fish/conf.d",
                "/etc/fish/conf.d",
            ])
        }

        var newest: Date?
        for path in paths {
            if let mtime = fileSystem.mtime(of: path) {
                if newest == nil || mtime > newest! { newest = mtime }
            }
        }
        for dir in directoriesToScan {
            // Directory mtime alone catches additions and deletions; per-file
            // mtimes catch in-place edits of the contained files.
            if let mtime = fileSystem.mtime(of: dir) {
                if newest == nil || mtime > newest! { newest = mtime }
            }
            for entry in fileSystem.contentsOfDirectory(atPath: dir) {
                if let mtime = fileSystem.mtime(of: "\(dir)/\(entry)") {
                    if newest == nil || mtime > newest! { newest = mtime }
                }
            }
        }
        return newest
    }

    // MARK: - Disk cache

    struct DiskCacheEntry: Codable {
        let version: Int
        let shell: String
        let path: String
        /// Wall-clock instant the cache file was written. Populated from the
        /// file's mtime on read; ignored on encode. Used for staleness
        /// comparison against shell init file mtimes.
        var cacheMtime: Date = .distantPast

        enum CodingKeys: String, CodingKey { case version, shell, path }
    }

    private static func readDiskCache() -> DiskCacheEntry? {
        guard let url = cacheFileURL() else { return nil }
        guard let data = try? Data(contentsOf: url),
              var entry = try? JSONDecoder().decode(DiskCacheEntry.self, from: data) else {
            return nil
        }
        guard entry.version == cacheFormatVersion, !entry.path.isEmpty else {
            return nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            entry.cacheMtime = mtime
        }
        return entry
    }

    private static func writeDiskCache(shell: String, path: String) {
        guard let url = cacheFileURL() else { return }
        let entry = DiskCacheEntry(version: cacheFormatVersion, shell: shell, path: path)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("failed to write PATH cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func cacheFileURL() -> URL? {
        guard let supportDir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return supportDir
            .appendingPathComponent("Soyeht", isDirectory: true)
            .appendingPathComponent(cacheFileName, isDirectory: false)
    }
}

/// Test seam for `latestDotfileMtime`. Production code uses
/// `DefaultFileSystem`; tests inject a stub that points at a tmp dir without
/// touching the real `$HOME` or `/etc`.
public protocol FileSystemProbing {
    var homeDirectoryPath: String { get }
    func mtime(of path: String) -> Date?
    func contentsOfDirectory(atPath: String) -> [String]
}

public struct DefaultFileSystem: FileSystemProbing {
    public init() {}
    public var homeDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
    public func mtime(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
    public func contentsOfDirectory(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
#endif
