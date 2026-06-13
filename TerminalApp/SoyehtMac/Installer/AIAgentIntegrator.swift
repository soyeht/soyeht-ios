import Foundation

/// Wires the Soyeht MCP server into the user-installed AI agent CLIs
/// (Claude Code, Codex, OpenCode, Droid). Apple-grade install path: the
/// user picks which agents during onboarding and the integrator writes the
/// MCP entry into each agent's config plus the global launcher in
/// `~/.local/bin/soyeht-mcp` — no terminal commands required from the user.
enum AIAgentIntegrator {

    enum Agent: String, CaseIterable, Identifiable, Hashable {
        case claudeCode
        case codex
        case opencode
        case droid

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex:      return "Codex"
            case .opencode:   return "OpenCode"
            case .droid:      return "Droid"
            }
        }

        /// CLI binary name used both for `which` detection and for the
        /// help text shown when the agent is missing.
        var cliName: String {
            switch self {
            case .claudeCode: return "claude"
            case .codex:      return "codex"
            case .opencode:   return "opencode"
            case .droid:      return "droid"
            }
        }

        /// Absolute path to the agent's MCP config file in $HOME.
        func configURL(home: URL) -> URL {
            switch self {
            case .claudeCode:
                return home.appendingPathComponent(".claude.json")
            case .codex:
                return home
                    .appendingPathComponent(".codex", isDirectory: true)
                    .appendingPathComponent("config.toml")
            case .opencode:
                return home
                    .appendingPathComponent(".config", isDirectory: true)
                    .appendingPathComponent("opencode", isDirectory: true)
                    .appendingPathComponent("opencode.json")
            case .droid:
                return home
                    .appendingPathComponent(".factory", isDirectory: true)
                    .appendingPathComponent("mcp.json")
            }
        }
    }

    enum IntegrationError: Error, LocalizedError {
        case bundledLauncherMissing
        case agentCLIMissing(Agent)
        case agentCommandFailed(Agent, output: String)
        case configWriteFailed(Agent, underlying: Error)
        case invalidJSONConfig(String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .bundledLauncherMissing:
                return "Soyeht.app bundle is missing the MCP server script. Reinstall the app."
            case .agentCLIMissing(let agent):
                return "\(agent.displayName) is not installed or could not be found on this Mac."
            case .agentCommandFailed(let agent, let output):
                return "\(agent.displayName) could not register the Soyeht MCP server: \(output)"
            case .configWriteFailed(let agent, let underlying):
                return "Could not update \(agent.displayName) config: \(underlying.localizedDescription)"
            case .invalidJSONConfig(let path, let underlying):
                return "Refusing to update malformed JSON config at \(path): \(underlying.localizedDescription)"
            }
        }
    }

    static let launcherKey = "soyeht"
    static let launcherURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("soyeht-mcp")

    // MARK: - Detection

    /// Whether the agent's CLI can be found. GUI apps often launch with a
    /// smaller PATH than Terminal, so detection checks both a login shell and
    /// the common install locations used by agent CLIs.
    @MainActor
    static func detect(_ agent: Agent) -> Bool {
        resolvedCLIURL(for: agent) != nil
    }

    private static func resolvedCLIURL(for agent: Agent) -> URL? {
        if let shellPath = shellResolvedCLIPath(agent.cliName),
           isExecutableFile(at: shellPath) {
            return URL(fileURLWithPath: shellPath)
        }
        return candidateCLIURLs(for: agent).first { isExecutableFile(at: $0.path) }
    }

    private static func shellResolvedCLIPath(_ cliName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(shellQuoted(cliName))"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        } catch {
            return nil
        }
    }

    @MainActor
    static func detectAll() -> [Agent: Bool] {
        Agent.allCases.reduce(into: [:]) { $0[$1] = detect($1) }
    }

    private static func candidateCLIURLs(for agent: Agent) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(agent.cliName),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(agent.cliName)"),
            URL(fileURLWithPath: "/usr/local/bin/\(agent.cliName)"),
            URL(fileURLWithPath: "/usr/bin/\(agent.cliName)"),
        ]
    }

    private static func isExecutableFile(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - Install

    /// Copies the bundled MCP server script into `~/.local/bin/soyeht-mcp`
    /// and writes the MCP entry into each selected agent's config. The
    /// launcher always reinstalls (idempotent), and each config write
    /// preserves existing entries — the only key Soyeht owns is its own.
    static func install(for agents: [Agent]) throws {
        try installLauncher()
        var errors: [Error] = []
        for agent in agents {
            do { try writeConfig(for: agent) }
            catch { errors.append(IntegrationError.configWriteFailed(agent, underlying: error)) }
        }
        if let first = errors.first { throw first }
    }

    private static func installLauncher() throws {
        guard let bundled = Bundle.main.url(forResource: "soyeht-mcp", withExtension: nil) else {
            throw IntegrationError.bundledLauncherMissing
        }
        let parent = launcherURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let launcherBody = """
        #!/usr/bin/env bash
        # Generated by Soyeht.app — do not edit. The Soyeht macOS app rewrites
        # this file every time the user re-runs the "Connect AI agents" step
        # in onboarding. Reinstalling Soyeht.app updates the absolute path.
        exec "\(bundled.path)" "$@"
        """
        try? FileManager.default.removeItem(at: launcherURL)
        try launcherBody.data(using: .utf8)!.write(to: launcherURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755 as Int16)],
            ofItemAtPath: launcherURL.path
        )
    }

    private static func writeConfig(for agent: Agent) throws {
        if agent == .claudeCode {
            try installClaudeCodeMCP()
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = agent.configURL(home: home)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        switch agent {
        case .claudeCode:
            break
        case .codex:
            try patchCodexTOML(at: configURL)
        case .opencode:
            try patchOpenCodeJSON(at: configURL)
        case .droid:
            try patchDroidJSON(at: configURL)
        }
    }

    private static func mcpEnvironment() throws -> [String: String] {
        let automationDir: String
        if let override = AppSupportDirectory.developerEnvironmentOverride("SOYEHT_AUTOMATION_DIR") {
            automationDir = override
        } else {
            automationDir = try AppSupportDirectory.subdirectory("Automation").path
        }
        return ["SOYEHT_AUTOMATION_DIR": automationDir]
    }

    // MARK: - Claude Code: claude mcp add-json --scope user soyeht ...

    private static func installClaudeCodeMCP() throws {
        guard let claudeURL = resolvedCLIURL(for: .claudeCode) else {
            throw IntegrationError.agentCLIMissing(.claudeCode)
        }
        let server = [
            "type": "stdio",
            "command": launcherURL.path,
            "args": [String](),
            "env": try mcpEnvironment(),
        ] as [String: Any]
        let serverData = try JSONSerialization.data(withJSONObject: server, options: [.sortedKeys])
        guard let serverJSON = String(data: serverData, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try runAgentCommand(
            .claudeCode,
            executableURL: claudeURL,
            arguments: ["mcp", "add-json", "--scope", "user", launcherKey, serverJSON]
        )
    }

    // MARK: - Codex: [mcp_servers.soyeht] command = "...", args = [], env

    /// Idempotently rewrites the `[mcp_servers.soyeht]` block in
    /// `~/.codex/config.toml`. Strips our own table AND any orphan
    /// sub-tables like `[mcp_servers.soyeht.tools.<name>]` left over from
    /// previous installs that configured per-tool approval modes — those
    /// would become dangling sections once the parent table moves, and a
    /// stray header was leaving the file syntactically invalid
    /// (`[]` on a tail line after a botched join). Then appends a fresh
    /// canonical block at end-of-file.
    private static func patchCodexTOML(at url: URL) throws {
        let env = try mcpEnvironment()
        let block = """
        [mcp_servers.\(launcherKey)]
        command = "\(launcherURL.path)"
        args = []

        [mcp_servers.\(launcherKey).env]
        SOYEHT_AUTOMATION_DIR = "\(tomlString(env["SOYEHT_AUTOMATION_DIR"] ?? ""))"
        """
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let stripped = SoyehtMCPConfigCleaner.removingSoyehtCodexBlocks(from: existing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if stripped.isEmpty {
            combined = block + "\n"
        } else {
            combined = stripped + "\n\n" + block + "\n"
        }
        try combined.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private static func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - OpenCode: .mcp.soyeht = { type:"local", command:[...], environment:{...}, enabled:true }

    private static func patchOpenCodeJSON(at url: URL) throws {
        var root = try readJSONObject(at: url)
        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }
        var mcp = (root["mcp"] as? [String: Any]) ?? [:]
        mcp[launcherKey] = [
            "type": "local",
            "command": [launcherURL.path],
            "environment": try mcpEnvironment(),
            "enabled": true,
        ] as [String: Any]
        root["mcp"] = mcp
        try writeJSONObject(root, to: url)
    }

    // MARK: - Droid: .mcpServers.soyeht = { type:stdio, command, args, env, disabled:false }

    private static func patchDroidJSON(at url: URL) throws {
        var root = try readJSONObject(at: url)
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[launcherKey] = [
            "type": "stdio",
            "command": launcherURL.path,
            "args": [String](),
            "env": try mcpEnvironment(),
            "disabled": false,
        ] as [String: Any]
        root["mcpServers"] = servers
        try writeJSONObject(root, to: url)
    }

    // MARK: - JSON helpers

    /// Reads a JSON object file or returns an empty object if missing/empty.
    /// Malformed JSON is never overwritten: replacing the user's config with a
    /// Soyeht-only object would destroy unrelated MCP entries and make install
    /// behavior differ across machines.
    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationError.invalidJSONConfig(url.path, underlying: CocoaError(.fileReadCorruptFile))
            }
            return object
        } catch let error as IntegrationError {
            throw error
        } catch {
            throw IntegrationError.invalidJSONConfig(url.path, underlying: error)
        }
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: []
        )
        try data.write(to: url, options: .atomic)
    }

    private static func runAgentCommand(_ agent: Agent, executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let data: Data
        do {
            try process.run()
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            throw IntegrationError.configWriteFailed(agent, underlying: error)
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "exit status \(process.terminationStatus)"
            throw IntegrationError.agentCommandFailed(agent, output: message)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
