#if os(macOS)
import Testing
import Foundation
@testable import SoyehtCore

@Suite struct LoginShellEnvironmentResolverParseTests {

    // MARK: - parseProbeOutput

    @Test("Extracts PATH from marker-delimited probe output")
    func extractsPathBetweenMarkers() {
        let raw = "banner from .zshrc\n__SOYEHT_PATH_START__/usr/local/bin:/usr/bin__SOYEHT_PATH_END__"
        let parsed = LoginShellEnvironmentResolver.parseProbeOutput(raw)
        #expect(parsed == "/usr/local/bin:/usr/bin")
    }

    @Test("Returns nil when probe markers are missing")
    func nilWhenMarkersAbsent() {
        #expect(LoginShellEnvironmentResolver.parseProbeOutput("/usr/bin:/bin") == nil)
        #expect(LoginShellEnvironmentResolver.parseProbeOutput("") == nil)
    }

    @Test("Returns nil when extracted PATH has no colon separator")
    func nilWhenPathLooksMalformed() {
        // Fish without `string join` would emit a space-separated list.
        let raw = "__SOYEHT_PATH_START__/usr/local/bin /opt/homebrew/bin__SOYEHT_PATH_END__"
        #expect(LoginShellEnvironmentResolver.parseProbeOutput(raw) == nil)
    }

    @Test("Returns nil when extracted PATH is empty")
    func nilWhenPathEmpty() {
        let raw = "__SOYEHT_PATH_START____SOYEHT_PATH_END__"
        #expect(LoginShellEnvironmentResolver.parseProbeOutput(raw) == nil)
    }

    // MARK: - probeScript

    @Test("POSIX shells use double-quoted $PATH")
    func posixShellsUseDoubleQuotedPath() {
        let bash = LoginShellEnvironmentResolver.probeScript(forShell: "/bin/bash")
        let zsh = LoginShellEnvironmentResolver.probeScript(forShell: "/bin/zsh")
        #expect(bash.contains("\"$PATH\""))
        #expect(zsh.contains("\"$PATH\""))
    }

    @Test("Fish gets a string-join expression instead of $PATH")
    func fishGetsStringJoinExpression() {
        let fish = LoginShellEnvironmentResolver.probeScript(forShell: "/opt/homebrew/bin/fish")
        #expect(fish.contains("string join : $PATH"))
        #expect(!fish.contains("\"$PATH\""))
    }

    // MARK: - parsePathHelperOutput

    @Test("Parses path_helper -s output into entries")
    func parsesPathHelperOutput() {
        let text = """
        PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; export PATH;
        MANPATH="/usr/local/share/man:/usr/share/man"; export MANPATH;
        """
        let entries = LoginShellEnvironmentResolver.parsePathHelperOutput(text)
        #expect(entries == ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }

    @Test("Returns nil when path_helper output has no PATH= line")
    func nilWhenPathHelperLacksPathLine() {
        #expect(LoginShellEnvironmentResolver.parsePathHelperOutput("MANPATH=\"/x\"; export MANPATH;") == nil)
        #expect(LoginShellEnvironmentResolver.parsePathHelperOutput("") == nil)
    }

    @Test("Returns nil when path_helper PATH line is missing closing quote")
    func nilWhenPathHelperLineUnterminated() {
        #expect(LoginShellEnvironmentResolver.parsePathHelperOutput("PATH=\"/usr/bin; export PATH;") == nil)
    }

    // MARK: - DiskCacheEntry round-trip

    @Test("Disk cache entry encodes the schema-stable fields and ignores cacheMtime")
    func diskCacheEntryRoundTrip() throws {
        let entry = LoginShellEnvironmentResolver.DiskCacheEntry(
            version: 1,
            shell: "/bin/zsh",
            path: "/opt/homebrew/bin:/usr/bin"
        )
        let data = try JSONEncoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        // cacheMtime must NOT be persisted; it's a derived runtime field
        // populated from the cache file's filesystem mtime on read.
        #expect(!json.contains("cacheMtime"))
        #expect(!json.contains("ageSeconds"))
        let decoded = try JSONDecoder().decode(
            LoginShellEnvironmentResolver.DiskCacheEntry.self,
            from: data
        )
        #expect(decoded.version == 1)
        #expect(decoded.shell == "/bin/zsh")
        #expect(decoded.path == "/opt/homebrew/bin:/usr/bin")
        #expect(decoded.cacheMtime == .distantPast)
    }
}

// MARK: - Staleness detection

/// In-memory `FileSystemProbing` so tests can describe a virtual home dir +
/// `/etc` layout without touching real files. Times are absolute so each
/// test controls the relative ordering precisely.
private struct StubFileSystem: FileSystemProbing {
    var homeDirectoryPath: String
    var files: [String: Date]
    var directories: [String: [String]]
    func mtime(of path: String) -> Date? { files[path] }
    func contentsOfDirectory(atPath path: String) -> [String] { directories[path] ?? [] }
}

@Suite struct LoginShellEnvironmentResolverStalenessTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var cacheMtime: Date { now.addingTimeInterval(-3600) } // 1h old
    private var staleCutoff: Date { now.addingTimeInterval(-31 * 86400) } // > 30d ago
    private let home = "/Users/test"

    @Test("Cache is fresh when no dotfile is newer and we're under the ceiling")
    func freshWhenAllOlder() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "\(home)/.zshrc": cacheMtime.addingTimeInterval(-7200),
                "/etc/zshrc": cacheMtime.addingTimeInterval(-86400),
            ],
            directories: [:]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/bin/zsh", fileSystem: fs)
        #expect(newest != nil)
        #expect(newest! < cacheMtime)
    }

    @Test("Cache is stale when ~/.zshrc was edited after the cache write")
    func staleWhenZshrcNewer() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "\(home)/.zshrc": cacheMtime.addingTimeInterval(60),
            ],
            directories: [:]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/bin/zsh", fileSystem: fs)
        #expect(newest != nil)
        #expect(newest! > cacheMtime)
    }

    @Test("~/.zshenv triggers staleness — covers users who put PATH in zshenv")
    func staleWhenZshenvNewer() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "\(home)/.zshenv": cacheMtime.addingTimeInterval(120),
            ],
            directories: [:]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/bin/zsh", fileSystem: fs)
        #expect(newest != nil)
        #expect(newest! > cacheMtime)
    }

    @Test("/etc/paths.d/ directory mtime triggers staleness — covers additions and deletions")
    func staleWhenPathsDDirectoryMtimeNewer() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "/etc/paths.d": cacheMtime.addingTimeInterval(30),
                "\(home)/.zshrc": cacheMtime.addingTimeInterval(-7200),
            ],
            directories: ["/etc/paths.d": []]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/bin/zsh", fileSystem: fs)
        #expect(newest != nil)
        #expect(newest! > cacheMtime)
    }

    @Test("/etc/paths.d/* file mtime triggers staleness when individual entry is edited")
    func staleWhenPathsDEntryNewer() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "/etc/paths.d": cacheMtime.addingTimeInterval(-86400),
                "/etc/paths.d/foo": cacheMtime.addingTimeInterval(45),
            ],
            directories: ["/etc/paths.d": ["foo"]]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/bin/zsh", fileSystem: fs)
        #expect(newest != nil)
        #expect(newest! > cacheMtime)
    }

    @Test("Fish user: ~/.config/fish/conf.d/foo.fish edits trigger staleness")
    func staleWhenFishConfDFileNewer_forFishShell() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "\(home)/.config/fish/conf.d/foo.fish": cacheMtime.addingTimeInterval(60),
            ],
            directories: ["\(home)/.config/fish/conf.d": ["foo.fish"]]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/opt/homebrew/bin/fish", fileSystem: fs)
        #expect(newest != nil)
        #expect(newest! > cacheMtime)
    }

    @Test("Non-fish user: fish files are NOT scanned, so editing them doesn't invalidate")
    func nonFishUserIgnoresFishFiles() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "\(home)/.config/fish/conf.d/foo.fish": cacheMtime.addingTimeInterval(60),
                "\(home)/.zshrc": cacheMtime.addingTimeInterval(-7200),
            ],
            directories: ["\(home)/.config/fish/conf.d": ["foo.fish"]]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/bin/zsh", fileSystem: fs)
        // Either nil (no candidates seen) or older than cacheMtime —
        // critically, NOT newer.
        if let newest { #expect(newest < cacheMtime) }
    }

    @Test("Returns nil when no candidate files exist (extreme edge case)")
    func nilWhenNoCandidatesExist() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [:],
            directories: [:]
        )
        let newest = LoginShellEnvironmentResolver.latestDotfileMtime(forShell: "/bin/zsh", fileSystem: fs)
        #expect(newest == nil)
    }

    @Test("cacheIsStale: under ceiling and no newer dotfile → fresh")
    func cacheIsStale_freshCase() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: [
                "\(home)/.zshrc": cacheMtime.addingTimeInterval(-7200),
                "/etc/zshrc": cacheMtime.addingTimeInterval(-86400),
            ],
            directories: [:]
        )
        let stale = LoginShellEnvironmentResolver.cacheIsStale(
            cacheMtime: cacheMtime,
            shell: "/bin/zsh",
            now: now,
            fileSystem: fs
        )
        #expect(!stale)
    }

    @Test("cacheIsStale: dotfile newer than cache → stale (under ceiling)")
    func cacheIsStale_dotfileTriggers() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: ["\(home)/.zshrc": cacheMtime.addingTimeInterval(60)],
            directories: [:]
        )
        let stale = LoginShellEnvironmentResolver.cacheIsStale(
            cacheMtime: cacheMtime,
            shell: "/bin/zsh",
            now: now,
            fileSystem: fs
        )
        #expect(stale)
    }

    @Test("cacheIsStale: cache older than 30-day ceiling → stale even with no dotfile changes")
    func cacheIsStale_ceilingTriggers() {
        let fs = StubFileSystem(
            homeDirectoryPath: home,
            files: ["\(home)/.zshrc": staleCutoff.addingTimeInterval(-86400)],
            directories: [:]
        )
        let stale = LoginShellEnvironmentResolver.cacheIsStale(
            cacheMtime: staleCutoff,
            shell: "/bin/zsh",
            now: now,
            fileSystem: fs
        )
        #expect(stale)
    }
}
#endif
