import XCTest

/// Runs the shell teardown script for real, in `--dry-run`, against a fixture
/// HOME — instead of matching its text.
///
/// The text guards in `MCPTeardownScriptGuardTests` are defeatable: a reviewer
/// demonstrated an edit that reassigns `SOYEHT_MCP_LAUNCHERS` to a single
/// element, keeps every string those guards look for, and silently stops
/// removing the development launcher. Only executing the script catches that.
final class MCPTeardownScriptExecutionTests: XCTestCase {

    private var fixtureHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("soyeht-teardown-fixture-\(UUID().uuidString)", isDirectory: true)

        let bin = fixtureHome.appendingPathComponent(".local/bin", isDirectory: true)
        let cache = fixtureHome
            .appendingPathComponent("Library/Caches/claude-cli-nodejs/-project", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // Ours, and two lookalikes that belong to somebody else.
        for launcher in ["soyeht-mcp", "soyeht-dev-mcp", "soyeht-mcp-someone-else"] {
            let url = bin.appendingPathComponent(launcher)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755 as Int16)], ofItemAtPath: url.path
            )
        }
        for dir in ["mcp-logs-soyeht", "mcp-logs-soyeht-dev",
                    "mcp-logs-soyeht-someone-else", "mcp-logs-soyehtfoo"] {
            try FileManager.default.createDirectory(
                at: cache.appendingPathComponent(dir, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        if let fixtureHome { try? FileManager.default.removeItem(at: fixtureHome) }
        try super.tearDownWithError()
    }

    func testUninstallerRemovesBothIdentitiesAndSparesLookalikes() throws {
        let planned = try dryRunPlan()

        XCTAssertTrue(planned.contains { $0.hasSuffix("/.local/bin/soyeht-mcp") },
                      "não removeu o lançador de release; plano = \(planned)")
        XCTAssertTrue(planned.contains { $0.hasSuffix("/.local/bin/soyeht-dev-mcp") },
                      "não removeu o lançador de dev; plano = \(planned)")
        XCTAssertTrue(planned.contains { $0.hasSuffix("/mcp-logs-soyeht") },
                      "não removeu os logs de release; plano = \(planned)")
        XCTAssertTrue(planned.contains { $0.hasSuffix("/mcp-logs-soyeht-dev") },
                      "não removeu os logs de dev; plano = \(planned)")

        for alheio in ["soyeht-mcp-someone-else", "mcp-logs-soyeht-someone-else", "mcp-logs-soyehtfoo"] {
            XCTAssertFalse(planned.contains { $0.hasSuffix("/\(alheio)") },
                           "reclamou \(alheio), que não é nosso; plano = \(planned)")
        }
    }

    /// `--dry-run` must plan, never delete.
    func testDryRunTouchesNothingOnDisk() throws {
        _ = try dryRunPlan()
        for survivor in [".local/bin/soyeht-mcp",
                         ".local/bin/soyeht-dev-mcp",
                         "Library/Caches/claude-cli-nodejs/-project/mcp-logs-soyeht-dev"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixtureHome.appendingPathComponent(survivor).path),
                "o dry-run apagou \(survivor)"
            )
        }
    }

    // MARK: -

    /// The paths the script says it would remove, restricted to the fixture so
    /// anything it plans outside it (system paths on the developer's Mac) is
    /// ignored.
    private func dryRunPlan() throws -> [String] {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/uninstall-soyeht-macos.sh")
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw XCTSkip("uninstall script not present at \(script.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--dry-run", "--yes", "--keep-app"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = fixtureHome.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        // Read while it runs: the pipe buffer would deadlock a chatty script.
        var data = Data()
        let handle = output.fileHandleForReading
        try process.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "o script saiu com \(process.terminationStatus)")

        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "[dry-run] rm -rf ") else { return nil }
                let path = String(line[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                return path.hasPrefix(fixtureHome.path) ? path : nil
            }
    }

    // MARK: - The repository installer, executed

    /// Running the MCP from a checkout is development, so the installer must
    /// write the development launcher unless told otherwise. Executed rather
    /// than matched, for the same reason as the teardown above.
    func testInstallerWritesTheLauncherOfTheRequestedIdentity() throws {
        let bin = fixtureHome.appendingPathComponent("install-target", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let byDefault = try runInstaller(identity: nil, binDirectory: bin)
        XCTAssertEqual(byDefault.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-dev-mcp").path),
                      "a omissão não escreveu o lançador de dev; saída = \(byDefault.text)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-mcp").path),
                       "a omissão escreveu o lançador da produção")
        XCTAssertTrue(byDefault.text.contains("soyeht-dev"), "não anunciou a chave a configurar")

        let release = try runInstaller(identity: "release", binDirectory: bin)
        XCTAssertEqual(release.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-mcp").path))
    }

    func testInstallerRefusesAnUnknownIdentityWithoutWritingAnything() throws {
        let bin = fixtureHome.appendingPathComponent("install-refuse", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let result = try runInstaller(identity: "producao", binDirectory: bin)
        XCTAssertEqual(result.status, 2, "devia sair com 2; saída = \(result.text)")
        let written = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        XCTAssertTrue(written.isEmpty, "escreveu \(written) apesar de recusar")
    }

    /// The installer must survive a broken `git`: a checkout that is not a
    /// repository, a worktree whose registration was removed, no git at all.
    /// It knows this failure mode because it happened — the worktree these
    /// tests run in lost its registration, every `git` call returned 128, and
    /// `set -euo pipefail` killed the script before it wrote anything.
    func testInstallerSurvivesABrokenGit() throws {
        let bin = fixtureHome.appendingPathComponent("install-nogit", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let result = try runInstaller(identity: nil, binDirectory: bin, sabotageGit: true)
        XCTAssertEqual(result.status, 0, "morreu com git avariado; saída = \(result.text)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-dev-mcp").path),
            "não escreveu o lançador com git avariado; saída = \(result.text)"
        )
    }

    /// A directory holding a `git` that always fails, to put first on PATH.
    private func brokenGitDirectory() throws -> URL {
        let dir = fixtureHome.appendingPathComponent("broken-git-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = dir.appendingPathComponent("git")
        try "#!/bin/sh\nexit 128\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755 as Int16)], ofItemAtPath: git.path
        )
        return dir
    }

    private func runInstaller(
        identity: String?,
        binDirectory: URL,
        sabotageGit: Bool = false
    ) throws -> (status: Int32, text: String) {
        let script = repoRoot().appendingPathComponent("scripts/install-soyeht-mcp")
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw XCTSkip("installer not present at \(script.path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SOYEHT_MCP_BIN_DIR"] = binDirectory.path
        if let identity { environment["SOYEHT_MCP_IDENTITY"] = identity }
        else { environment.removeValue(forKey: "SOYEHT_MCP_IDENTITY") }
        if sabotageGit {
            let stub = try brokenGitDirectory().path
            environment["PATH"] = stub + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var data = Data()
        let handle = pipe.fileHandleForReading
        try process.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
