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
        case configWriteFailed(Agent, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .bundledLauncherMissing:
                return "Soyeht.app bundle is missing the MCP server script. Reinstall the app."
            case .configWriteFailed(let agent, let underlying):
                return "Could not update \(agent.displayName) config: \(underlying.localizedDescription)"
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

    /// Whether the agent's CLI is on the user's PATH. Uses `command -v`
    /// inside a login-style shell so PATH additions from `.zshrc` /
    /// `.profile` are honored — without this an agent installed via
    /// Homebrew that only `eval`s `brew shellenv` from the rc file would
    /// be invisible.
    @MainActor
    static func detect(_ agent: Agent) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(agent.cliName) >/dev/null"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @MainActor
    static func detectAll() -> [Agent: Bool] {
        Agent.allCases.reduce(into: [:]) { $0[$1] = detect($1) }
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = agent.configURL(home: home)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        switch agent {
        case .claudeCode:
            try patchClaudeJSON(at: configURL)
        case .codex:
            try patchCodexTOML(at: configURL)
        case .opencode:
            try patchOpenCodeJSON(at: configURL)
        case .droid:
            try patchDroidJSON(at: configURL)
        }
    }

    // MARK: - Claude Code: .mcpServers.soyeht = { type:stdio, command, args:[], env:{} }

    private static func patchClaudeJSON(at url: URL) throws {
        var root = try readJSONObject(at: url)
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[launcherKey] = [
            "type": "stdio",
            "command": launcherURL.path,
            "args": [String](),
            "env": [String: String](),
        ] as [String: Any]
        root["mcpServers"] = servers
        try writeJSONObject(root, to: url)
    }

    // MARK: - Codex: [mcp_servers.soyeht] command = "...", args = []

    /// Idempotently rewrites the `[mcp_servers.soyeht]` block in
    /// `~/.codex/config.toml`. Strips our own table AND any orphan
    /// sub-tables like `[mcp_servers.soyeht.tools.<name>]` left over from
    /// previous installs that configured per-tool approval modes — those
    /// would become dangling sections once the parent table moves, and a
    /// stray header was leaving the file syntactically invalid
    /// (`[]` on a tail line after a botched join). Then appends a fresh
    /// canonical block at end-of-file.
    private static func patchCodexTOML(at url: URL) throws {
        let block = """
        [mcp_servers.\(launcherKey)]
        command = "\(launcherURL.path)"
        args = []
        """
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Regex strips any `[mcp_servers.soyeht]` table or sub-table
        // (`[mcp_servers.soyeht.anything]`) plus all the key/value lines
        // that belong to it (everything up to the next `[` header or EOF).
        let pattern = "(?m)^\\[mcp_servers\\.\(launcherKey)(\\..*)?\\][^\\[]*"
        let stripped = existing
            .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if stripped.isEmpty {
            combined = block + "\n"
        } else {
            combined = stripped + "\n\n" + block + "\n"
        }
        try combined.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    // MARK: - OpenCode: .mcp.soyeht = { type:"local", command:[...], enabled:true }

    private static func patchOpenCodeJSON(at url: URL) throws {
        var root = try readJSONObject(at: url)
        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }
        var mcp = (root["mcp"] as? [String: Any]) ?? [:]
        mcp[launcherKey] = [
            "type": "local",
            "command": [launcherURL.path],
            "enabled": true,
        ] as [String: Any]
        root["mcp"] = mcp
        try writeJSONObject(root, to: url)
    }

    // MARK: - Droid: .mcpServers.soyeht = { type:stdio, command, args, disabled:false }

    private static func patchDroidJSON(at url: URL) throws {
        var root = try readJSONObject(at: url)
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[launcherKey] = [
            "type": "stdio",
            "command": launcherURL.path,
            "args": [String](),
            "disabled": false,
        ] as [String: Any]
        root["mcpServers"] = servers
        try writeJSONObject(root, to: url)
    }

    // MARK: - JSON helpers

    /// Reads a JSON object file or returns an empty object if missing or
    /// unparseable. We deliberately never throw on malformed input — the
    /// integrator should add Soyeht's entry without destroying the user's
    /// other settings, but a corrupted config is better than refusing to
    /// install. If parse fails the caller's existing entries are lost,
    /// which is acceptable given the original was already invalid.
    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
