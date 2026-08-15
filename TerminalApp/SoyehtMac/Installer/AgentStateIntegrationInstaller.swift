import CryptoKit
import Foundation
import os

/// Installs the agent-state reporters into the user's agent configurations
/// (Claude Code hooks, Codex hooks, OpenCode plugin, Qwen
/// Code hooks, Antigravity CLI plugin, pi extension, Droid hooks), herdr-style.
///
/// Design rules (from integration review):
/// * Reporters are env-gated: inert outside Soyeht panes.
/// * Merges are surgical: only handlers owned by Soyeht (identified by the
///   managed script path in the command) are added/replaced/removed; every
///   other key, array and handler is preserved. Writes are atomic with a
///   one-time backup.
/// * Codex hooks are synchronous (async hooks are skipped by codex 0.147).
/// * Hook timeouts are agent-specific units: claude/codex use seconds,
///   qwen uses milliseconds.
/// * `CodexHookAudit` decides whether the codex launch may add
///   `--dangerously-bypass-hook-trust`: only when EVERY discovered hook is
///   Soyeht-owned and the installed script matches the bundled hash
///   (fail closed otherwise).
enum AgentStateIntegrationInstaller {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "agent-integrations")
    static let markerScriptName = "soyeht-agent-state"
    private static let versionDefaultsKey = "soyeht.agentStateIntegration.version"
    private static let claudeScriptHashKey = "soyeht.agentStateIntegration.claudeScriptHash"
    private static let codexScriptHashKey = "soyeht.agentStateIntegration.codexScriptHash"
    private static let opencodeScriptHashKey = "soyeht.agentStateIntegration.opencodeScriptHash"
    private static let qwenScriptHashKey = "soyeht.agentStateIntegration.qwenScriptHash"
    private static let agyScriptHashKey = "soyeht.agentStateIntegration.agyScriptHash"
    private static let piScriptHashKey = "soyeht.agentStateIntegration.piScriptHash"
    private static let droidScriptHashKey = "soyeht.agentStateIntegration.droidScriptHash"
    private static let kiloScriptHashKey = "soyeht.agentStateIntegration.kiloScriptHash"
    private static let cursorScriptHashKey = "soyeht.agentStateIntegration.cursorScriptHash"
    private static let copilotScriptHashKey = "soyeht.agentStateIntegration.copilotScriptHash"
    private static let grokScriptHashKey = "soyeht.agentStateIntegration.grokScriptHash"
    private static let kimiScriptHashKey = "soyeht.agentStateIntegration.kimiScriptHash"
    private static let devinScriptHashKey = "soyeht.agentStateIntegration.devinScriptHash"
    private static let allAgents = ["claude", "codex", "opencode", "qwen", "antigravity", "pi", "droid", "kilo", "cursor", "copilot", "grok", "kimi", "devin"]

    struct Summary {
        var installed: [String] = []
        var skipped: [String] = []
        var failed: [String] = []
    }

    @MainActor
    static func installAllIfNeeded() -> Summary {
        let defaults = UserDefaults.standard
        let installedVersion = defaults.integer(forKey: versionDefaultsKey)
        let hashesMatch =
            defaults.string(forKey: claudeScriptHashKey) == sha256(claudeScriptPath())
            && defaults.string(forKey: codexScriptHashKey) == sha256(codexScriptPath())
            && defaults.string(forKey: opencodeScriptHashKey) == sha256OrNil(opencodePluginPath())
            && defaults.string(forKey: qwenScriptHashKey) == sha256OrNil(qwenScriptPath())
            && defaults.string(forKey: agyScriptHashKey) == agyExpectedHash()
            && defaults.string(forKey: piScriptHashKey) == sha256OrNil(piExtensionPath())
            && defaults.string(forKey: droidScriptHashKey) == sha256OrNil(droidScriptPath())
            && defaults.string(forKey: kiloScriptHashKey) == sha256OrNil(kiloPluginPath())
            && defaults.string(forKey: cursorScriptHashKey) == sha256OrNil(cursorScriptPath())
            && defaults.string(forKey: copilotScriptHashKey) == sha256OrNil(copilotScriptPath())
            && defaults.string(forKey: grokScriptHashKey) == sha256OrNil(grokScriptPath())
            && defaults.string(forKey: kimiScriptHashKey) == sha256OrNil(kimiScriptPath())
            && defaults.string(forKey: devinScriptHashKey) == sha256OrNil(devinScriptPath())
        if installedVersion == AgentStateReporterScripts.version, hashesMatch {
            return Summary(skipped: allAgents)
        }
        let summary = installAll()
        defaults.set(AgentStateReporterScripts.version, forKey: versionDefaultsKey)
        persistInstalledHash(sha256(claudeScriptPath()), key: claudeScriptHashKey, agent: "claude", summary: summary, defaults: defaults)
        persistInstalledHash(sha256(codexScriptPath()), key: codexScriptHashKey, agent: "codex", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(opencodePluginPath()), key: opencodeScriptHashKey, agent: "opencode", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(qwenScriptPath()), key: qwenScriptHashKey, agent: "qwen", summary: summary, defaults: defaults)
        persistInstalledHash(agyExpectedHash(), key: agyScriptHashKey, agent: "antigravity", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(piExtensionPath()), key: piScriptHashKey, agent: "pi", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(droidScriptPath()), key: droidScriptHashKey, agent: "droid", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(kiloPluginPath()), key: kiloScriptHashKey, agent: "kilo", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(cursorScriptPath()), key: cursorScriptHashKey, agent: "cursor", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(copilotScriptPath()), key: copilotScriptHashKey, agent: "copilot", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(grokScriptPath()), key: grokScriptHashKey, agent: "grok", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(kimiScriptPath()), key: kimiScriptHashKey, agent: "kimi", summary: summary, defaults: defaults)
        persistInstalledHash(sha256OrNil(devinScriptPath()), key: devinScriptHashKey, agent: "devin", summary: summary, defaults: defaults)
        return summary
    }

    /// A failed per-agent write must remain pending. Recording the hash of an
    /// older file after a partial install makes the next launch believe the
    /// stale integration is current merely because its hash is self-consistent.
    private static func persistInstalledHash(
        _ hash: String?,
        key: String,
        agent: String,
        summary: Summary,
        defaults: UserDefaults
    ) {
        if summary.installed.contains(agent) {
            defaults.set(hash, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    @MainActor
    static func installAll() -> Summary {
        var summary = Summary()
        do {
            try installClaude()
            summary.installed.append("claude")
        } catch {
            summary.failed.append("claude: \(error.localizedDescription)")
        }
        do {
            try installCodex()
            summary.installed.append("codex")
        } catch {
            summary.failed.append("codex: \(error.localizedDescription)")
        }
        do {
            try installOpencode()
            summary.installed.append("opencode")
        } catch {
            summary.failed.append("opencode: \(error.localizedDescription)")
        }
        do {
            try installQwen()
            summary.installed.append("qwen")
        } catch {
            summary.failed.append("qwen: \(error.localizedDescription)")
        }
        do {
            try installAntigravity()
            summary.installed.append("antigravity")
        } catch {
            summary.failed.append("antigravity: \(error.localizedDescription)")
        }
        do {
            try installPi()
            summary.installed.append("pi")
        } catch {
            summary.failed.append("pi: \(error.localizedDescription)")
        }
        do {
            try installDroid()
            summary.installed.append("droid")
        } catch {
            summary.failed.append("droid: \(error.localizedDescription)")
        }
        do {
            try installKilo()
            summary.installed.append("kilo")
        } catch {
            summary.failed.append("kilo: \(error.localizedDescription)")
        }
        do {
            try installCursor()
            summary.installed.append("cursor")
        } catch {
            summary.failed.append("cursor: \(error.localizedDescription)")
        }
        do {
            try installCopilot()
            summary.installed.append("copilot")
        } catch {
            summary.failed.append("copilot: \(error.localizedDescription)")
        }
        do {
            try installGrok()
            summary.installed.append("grok")
        } catch {
            summary.failed.append("grok: \(error.localizedDescription)")
        }
        do {
            try installKimi()
            summary.installed.append("kimi")
        } catch {
            summary.failed.append("kimi: \(error.localizedDescription)")
        }
        do {
            try installDevin()
            summary.installed.append("devin")
        } catch {
            summary.failed.append("devin: \(error.localizedDescription)")
        }
        logger.info(
            "integrations_install installed=\(summary.installed.joined(separator: ","), privacy: .public) failed=\(summary.failed.joined(separator: " | "), privacy: .public)"
        )
        return summary
    }

    // MARK: - Claude Code

    static func claudeHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func claudeScriptPath() -> URL {
        claudeHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installClaude() throws {
        let claudeDir = claudeHome()
        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            throw IntegrationError.agentHomeMissing(".claude")
        }
        try writeScript(
            to: claudeScriptPath(),
            content: AgentStateReporterScripts.claudeCodexHookReporter
        )

        let settingsPath = claudeDir.appendingPathComponent("settings.json")
        var root = readJsonObject(at: settingsPath) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let eventsAsync: [(event: String, matcher: String?)] = [
            ("SessionStart", nil),
            ("UserPromptSubmit", nil),
            ("MessageDisplay", nil),
            ("PreToolUse", nil),
            ("PostToolUse", nil),
            ("PermissionRequest", nil),
            ("Notification", "permission_prompt"),
            ("Stop", nil),
        ]
        for (event, matcher) in eventsAsync {
            let mustPersistConversationBeforeContinuing = [
                "SessionStart", "UserPromptSubmit", "MessageDisplay", "Stop",
            ].contains(event)
            hooks[event] = mergedGroups(
                existing: hooks[event] as? [[String: Any]] ?? [],
                replacement: hookGroup(
                    command: claudeHookCommand(),
                    matcher: matcher,
                    async: !mustPersistConversationBeforeContinuing
                )
            )
        }
        root["hooks"] = hooks
        try writeJsonAtomically(root, to: settingsPath, backupName: "settings.json.soyeht-backup")
    }

    private static func claudeHookCommand() -> String {
        "SOYEHT_REPORT_AGENT=claude python3 \"\(claudeScriptPath().path)\""
    }

    // MARK: - Codex

    static func codexHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func codexScriptPath() -> URL {
        codexHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installCodex() throws {
        let codexDir = codexHome()
        guard FileManager.default.fileExists(atPath: codexDir.path) else {
            throw IntegrationError.agentHomeMissing(".codex")
        }
        try writeScript(
            to: codexScriptPath(),
            content: AgentStateReporterScripts.claudeCodexHookReporter
        )

        let hooksPath = codexDir.appendingPathComponent("hooks.json")
        var root = readJsonObject(at: hooksPath) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        // Codex 0.147 skips async command hooks: reporters stay synchronous.
        let events: [String] = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
        ]
        for event in events {
            hooks[event] = mergedGroups(
                existing: hooks[event] as? [[String: Any]] ?? [],
                replacement: hookGroup(
                    command: codexHookCommand(),
                    matcher: nil,
                    async: false
                )
            )
        }
        root["hooks"] = hooks
        try writeJsonAtomically(root, to: hooksPath, backupName: "hooks.json.soyeht-backup")
    }

    private static func codexHookCommand() -> String {
        "SOYEHT_REPORT_AGENT=codex python3 \"\(codexScriptPath().path)\""
    }

    // MARK: - OpenCode

    static func opencodePluginPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins/soyeht-agent-state.js")
    }

    static func installOpencode() throws {
        let opencodeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode")
        guard FileManager.default.fileExists(atPath: opencodeDir.path) else {
            throw IntegrationError.agentHomeMissing(".config/opencode")
        }
        try writeScript(
            to: opencodePluginPath(),
            content: AgentStateReporterScripts.opencodeStructuredPluginReporter
        )
    }

    // MARK: - Antigravity CLI (shares ~/.gemini)

    static func geminiHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }

    // MARK: - Qwen Code

    static func qwenHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".qwen")
    }

    static func qwenScriptPath() -> URL {
        qwenHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installQwen() throws {
        let qwenDir = qwenHome()
        guard FileManager.default.fileExists(atPath: qwenDir.path) else {
            throw IntegrationError.agentHomeMissing(".qwen")
        }
        try writeScript(
            to: qwenScriptPath(),
            content: AgentStateReporterScripts.claudeCodexHookReporter
        )

        let settingsPath = qwenDir.appendingPathComponent("settings.json")
        var root = readJsonObject(at: settingsPath) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        // Qwen Code is a gemini-cli fork that kept the Claude Code hook
        // schema (same event names), so the shared reporter applies. Async
        // hooks are supported; timeout unit is milliseconds.
        let events: [String] = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Notification",
            "Stop",
            "SessionEnd",
        ]
        for event in events {
            hooks[event] = mergedGroups(
                existing: hooks[event] as? [[String: Any]] ?? [],
                replacement: hookGroup(
                    command: qwenHookCommand(),
                    matcher: nil,
                    async: true,
                    timeout: 5000
                )
            )
        }
        root["hooks"] = hooks
        try writeJsonAtomically(root, to: settingsPath, backupName: "settings.json.soyeht-backup")
    }

    private static func qwenHookCommand() -> String {
        "SOYEHT_REPORT_AGENT=qwen python3 \"\(qwenScriptPath().path)\""
    }

    // MARK: - Antigravity CLI (agy)

    static func agyPluginDir() -> URL {
        geminiHome().appendingPathComponent("antigravity-cli/plugins/soyeht-agent-state")
    }

    static func agyReporterPath() -> URL {
        agyPluginDir().appendingPathComponent("reporter.py")
    }

    /// Locates the agy binary: the official installer puts it in
    /// ~/.local/bin, but Homebrew/custom installs are honored too.
    static func agyBinaryPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("agy")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func installAntigravity() throws {
        guard let agyBin = agyBinaryPath() else {
            throw IntegrationError.agentHomeMissing(".local/bin/agy")
        }
        let pluginDir = agyPluginDir()
        try writeScript(
            to: pluginDir.appendingPathComponent("plugin.json"),
            content: AgentStateReporterScripts.antigravityPluginManifest
        )
        try writeScript(
            to: agyReporterPath(),
            content: AgentStateReporterScripts.claudeCompatibleStructuredReporter(agent: "antigravity")
        )
        let hooks = AgentStateReporterScripts.antigravityPluginHooks.replacingOccurrences(
            of: "__REPORTER__",
            with: agyReporterPath().path
        )
        try writeScript(to: pluginDir.appendingPathComponent("hooks.json"), content: hooks)

        // agy only runs hooks from plugins registered through its import
        // registry, so stage + install through the CLI itself. Re-running
        // install on an already-imported plugin refreshes it in place.
        let process = Process()
        process.executableURL = agyBin
        process.arguments = ["plugin", "install", pluginDir.path]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw IntegrationError.invalidJson("agy plugin install failed: \(message.prefix(200))")
        }
    }

    /// Staleness marker for the agy integration: nil when agy is not
    /// installed, "missing" when it is installed but the reporter is gone.
    static func agyExpectedHash() -> String? {
        guard agyBinaryPath() != nil else { return nil }
        if FileManager.default.fileExists(atPath: agyReporterPath().path) {
            return sha256(agyReporterPath())
        }
        return "missing"
    }

    // MARK: - pi (earendil)

    static func piHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi")
    }

    static func piExtensionPath() -> URL {
        piHome().appendingPathComponent("agent/extensions/soyeht-agent-state.ts")
    }

    static func installPi() throws {
        let piDir = piHome()
        guard FileManager.default.fileExists(atPath: piDir.path) else {
            throw IntegrationError.agentHomeMissing(".pi")
        }
        try writeScript(
            to: piExtensionPath(),
            content: AgentStateReporterScripts.piExtensionReporter
        )
    }

    // MARK: - Droid (Factory)

    static func droidHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory")
    }

    static func droidScriptPath() -> URL {
        droidHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installDroid() throws {
        let droidDir = droidHome()
        guard FileManager.default.fileExists(atPath: droidDir.path) else {
            throw IntegrationError.agentHomeMissing(".factory")
        }
        // Droid speaks the Claude Code hook protocol (same stdin payload and
        // hooks.json schema), so the shared reporter applies verbatim.
        try writeScript(
            to: droidScriptPath(),
            content: AgentStateReporterScripts.claudeCodexHookReporter
        )

        let hooksPath = droidDir.appendingPathComponent("hooks.json")
        var root = readJsonObject(at: hooksPath) ?? [:]
        let events: [String] = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "Notification",
            "Stop",
        ]
        for event in events {
            root[event] = mergedGroups(
                existing: root[event] as? [[String: Any]] ?? [],
                replacement: hookGroup(
                    command: droidHookCommand(),
                    matcher: nil,
                    async: false
                )
            )
        }
        try writeJsonAtomically(root, to: hooksPath, backupName: "hooks.json.soyeht-backup")

        // Hooks are gated behind `enableHooks` in droid settings; turn the
        // flag on (one-time backup) or the hooks above never run.
        let settingsPath = droidDir.appendingPathComponent("settings.json")
        if var settings = readJsonObject(at: settingsPath),
           (settings["enableHooks"] as? Bool) != true {
            settings["enableHooks"] = true
            try writeJsonAtomically(settings, to: settingsPath, backupName: "settings.json.soyeht-backup")
        }
    }

    private static func droidHookCommand() -> String {
        "SOYEHT_REPORT_AGENT=droid python3 \"\(droidScriptPath().path)\""
    }

    // MARK: - Kilo Code CLI

    static func kiloPluginPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kilo/plugin/soyeht-agent-state.js")
    }

    static func installKilo() throws {
        let kiloDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kilo")
        guard FileManager.default.fileExists(atPath: kiloDir.path) else {
            throw IntegrationError.agentHomeMissing(".config/kilo")
        }
        try writeScript(
            to: kiloPluginPath(),
            content: AgentStateReporterScripts.kiloPluginReporter
        )
    }

    // MARK: - Cursor CLI

    static func cursorHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    }

    static func cursorScriptPath() -> URL {
        cursorHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installCursor() throws {
        let cursorDir = cursorHome()
        guard FileManager.default.fileExists(atPath: cursorDir.path) else {
            throw IntegrationError.agentHomeMissing(".cursor")
        }
        try writeScript(
            to: cursorScriptPath(),
            content: AgentStateReporterScripts.claudeCompatibleStructuredReporter(agent: "cursor")
        )

        // Cursor hooks.json schema: {"version": 1, "hooks": {event: [{command}]}}
        // (flat entries, unlike the Claude-style matcher/hooks groups).
        let hooksPath = cursorDir.appendingPathComponent("hooks.json")
        var root = readJsonObject(at: hooksPath) ?? [:]
        root["version"] = 1
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let events: [String] = [
            "sessionStart",
            "beforeSubmitPrompt",
            "beforeShellExecution",
            "beforeMCPExecution",
            "beforeReadFile",
            "stop",
            "sessionEnd",
        ]
        for event in events {
            let existing = hooks[event] as? [[String: Any]] ?? []
            let cleaned = existing.filter { entry in
                let command = entry["command"] as? String ?? ""
                return !command.contains(markerScriptName)
            }
            hooks[event] = cleaned + [["command": cursorHookCommand(), "timeout": 10]]
        }
        root["hooks"] = hooks
        try writeJsonAtomically(root, to: hooksPath, backupName: "hooks.json.soyeht-backup")
    }

    private static func cursorHookCommand() -> String {
        "SOYEHT_REPORT_AGENT=cursor python3 \"\(cursorScriptPath().path)\""
    }

    // MARK: - GitHub Copilot CLI

    static func copilotHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
    }

    static func copilotScriptPath() -> URL {
        copilotHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installCopilot() throws {
        let copilotDir = copilotHome()
        guard FileManager.default.fileExists(atPath: copilotDir.path) else {
            throw IntegrationError.agentHomeMissing(".copilot")
        }
        try writeScript(
            to: copilotScriptPath(),
            content: AgentStateReporterScripts.claudeCompatibleStructuredReporter(agent: "copilot")
        )

        // Copilot personal hooks live in ~/.copilot/hooks/*.json. We own one
        // dedicated file; other hook files are untouched. Copilot payloads
        // carry no event name, so each entry injects SOYEHT_HOOK_EVENT.
        let events: [String] = [
            "sessionStart",
            "userPromptSubmitted",
            "preToolUse",
            "postToolUse",
            "agentStop",
            "errorOccurred",
            "sessionEnd",
        ]
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [[
                "type": "command",
                "bash": "python3 \"\(copilotScriptPath().path)\"",
                "env": ["SOYEHT_HOOK_EVENT": event],
                "timeoutSec": 10,
            ]]
        }
        let root: [String: Any] = ["version": 1, "hooks": hooks]
        let hooksPath = copilotDir.appendingPathComponent("hooks/soyeht-agent-state.json")
        try writeJsonAtomically(root, to: hooksPath, backupName: "soyeht-agent-state.json.soyeht-backup")
    }

    // MARK: - Grok CLI (xAI)

    static func grokHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    static func grokScriptPath() -> URL {
        grokHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installGrok() throws {
        let grokDir = grokHome()
        guard FileManager.default.fileExists(atPath: grokDir.path) else {
            throw IntegrationError.agentHomeMissing(".grok")
        }
        try writeScript(
            to: grokScriptPath(),
            content: AgentStateReporterScripts.claudeCompatibleStructuredReporter(agent: "grok")
        )
        // Global hooks dir (~/.grok/hooks/*.json) is always trusted by grok.
        // Grok executes hook commands directly (no shell), so the command is
        // a bare `python3 <script>` — no VAR=... prefix. Note: `grok
        // inspect` does not list these files, but they execute.
        let events: [String] = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "Stop",
            "SessionEnd",
        ]
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "python3 \"\(grokScriptPath().path)\"",
                    "timeout": 5,
                ]],
            ]]
        }
        let root: [String: Any] = ["hooks": hooks]
        try writeJsonAtomically(
            root,
            to: grokDir.appendingPathComponent("hooks/soyeht-agent-state.json"),
            backupName: "soyeht-agent-state.json.soyeht-backup"
        )
    }

    // MARK: - Kimi Code CLI (Moonshot)

    static func kimiHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    static func kimiScriptPath() -> URL {
        kimiHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installKimi() throws {
        let kimiDir = kimiHome()
        guard FileManager.default.fileExists(atPath: kimiDir.path) else {
            throw IntegrationError.agentHomeMissing(".kimi-code")
        }
        try writeScript(
            to: kimiScriptPath(),
            content: AgentStateReporterScripts.claudeCompatibleStructuredReporter(agent: "kimi")
        )

        // Hooks live in ~/.kimi-code/config.toml as [[hooks]] entries. We own
        // a marker-delimited block: rewrite only between the markers so other
        // user config stays intact. Only the classic event set — newer event
        // names (TurnStarted, PermissionResult, ...) make older kimi-code
        // reject the whole config.
        let events: [String] = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
            "SessionEnd",
        ]
        var block: [String] = ["# --- soyeht-agent-state: begin ---"]
        for event in events {
            block.append("[[hooks]]")
            block.append("event = \"\(event)\"")
            block.append("command = 'python3 \"\(kimiScriptPath().path)\"'")
            block.append("timeout = 5")
            block.append("")
        }
        block.append("# --- soyeht-agent-state: end ---")

        let configPath = kimiDir.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
        let beginMarker = "# --- soyeht-agent-state: begin ---"
        let endMarker = "# --- soyeht-agent-state: end ---"
        var cleaned = existing
        if let beginRange = existing.range(of: beginMarker),
           let endRange = existing.range(of: endMarker),
           beginRange.lowerBound < endRange.upperBound {
            cleaned.removeSubrange(beginRange.lowerBound ..< endRange.upperBound)
            while cleaned.hasSuffix("\n\n") {
                cleaned.removeLast()
            }
        }
        let separator = cleaned.isEmpty || cleaned.hasSuffix("\n") ? "\n" : "\n\n"
        let updated = cleaned + separator + block.joined(separator: "\n") + "\n"
        if FileManager.default.fileExists(atPath: configPath.path) {
            let backup = configPath.deletingLastPathComponent()
                .appendingPathComponent("config.toml.soyeht-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: configPath, to: backup)
            }
        }
        try updated.data(using: .utf8)?.write(to: configPath, options: .atomic)
    }

    // MARK: - Devin CLI (Cognition)

    static func devinHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/devin")
    }

    static func devinScriptPath() -> URL {
        devinHome().appendingPathComponent("hooks/soyeht-agent-state.py")
    }

    static func installDevin() throws {
        let devinDir = devinHome()
        guard FileManager.default.fileExists(atPath: devinDir.path) else {
            throw IntegrationError.agentHomeMissing(".config/devin")
        }
        try writeScript(
            to: devinScriptPath(),
            content: AgentStateReporterScripts.claudeCompatibleStructuredReporter(agent: "devin")
        )

        // Devin user hooks live in ~/.config/devin/config.json under "hooks".
        // Note: devin also picks up ~/.claude/settings.json hooks by default
        // (read_config_from.claude); the claude reporter may fire alongside —
        // harmless (same states), our devin reporter is the attribution
        // source of record since it reports with tool names.
        let events: [String] = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
            "SessionEnd",
        ]
        let configPath = devinDir.appendingPathComponent("config.json")
        var root = readJsonObject(at: configPath) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let command = "python3 \"\(devinScriptPath().path)\""
        for event in events {
            let existing = hooks[event] as? [[String: Any]] ?? []
            let cleaned = existing.filter { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return !handlers.contains { ($0["command"] as? String ?? "").contains(markerScriptName) }
            }
            hooks[event] = cleaned + [[
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 5,
                ]],
            ]]
        }
        root["hooks"] = hooks
        try writeJsonAtomically(root, to: configPath, backupName: "config.json.soyeht-backup")
    }

    // MARK: - Merge helpers

    enum IntegrationError: LocalizedError {
        case agentHomeMissing(String)
        case invalidJson(String)

        var errorDescription: String? {
            switch self {
            case .agentHomeMissing(let name):
                return "Agent config directory not found: ~/\(name) (agent not installed)."
            case .invalidJson(let path):
                return "Could not parse JSON at \(path)."
            }
        }
    }

    /// One Soyeht-owned matcher group containing a single command handler.
    private static func hookGroup(command: String, matcher: String?, async: Bool, timeout: Int = 5) -> [String: Any] {
        var handler: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": timeout,
        ]
        if async {
            handler["async"] = true
        }
        var group: [String: Any] = ["hooks": [handler]]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    /// Removes existing Soyeht-owned handlers from `existing` (anywhere), then
    /// appends `replacement`. Non-Soyeht groups/handlers are preserved intact.
    private static func mergedGroups(existing: [[String: Any]], replacement: [String: Any]) -> [[String: Any]] {
        let cleaned: [[String: Any]] = existing.compactMap { groupIn in
            var group = groupIn
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let kept = handlers.filter { handler in
                let command = handler["command"] as? String ?? ""
                return !command.contains(markerScriptName)
            }
            if kept.isEmpty {
                return nil
            }
            group["hooks"] = kept
            return group
        }
        return cleaned + [replacement]
    }

    private static func writeScript(to url: URL, content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func readJsonObject(at url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func writeJsonAtomically(_ object: [String: Any], to url: URL, backupName: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
        }
        let tmp = url.appendingPathExtension("soyeht-tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    static func sha256(_ path: URL) -> String? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash check for optional agents: a missing script must not look like a
    /// tampered one when the agent home itself does not exist (agent never
    /// installed), so staleness only triggers when the home exists but the
    /// script is missing or differs.
    static func sha256OrNil(_ path: URL) -> String? {
        if FileManager.default.fileExists(atPath: path.path) {
            return sha256(path)
        }
        if FileManager.default.fileExists(atPath: path.deletingLastPathComponent().deletingLastPathComponent().path) {
            return "missing"
        }
        return nil
    }
}

/// Codex hook trust gate. `--dangerously-bypass-hook-trust` applies to the
/// whole invocation, so it is only safe when every hook codex would discover
/// is Soyeht-owned and byte-identical to what the installer wrote. Anything
/// else (user hooks, project hooks, modified reporter) fails closed: no
/// bypass, hooks follow codex's normal trust review.
enum CodexHookAudit {
    static func bypassAllowed() -> Bool {
        guard let expectedHash = UserDefaults.standard.string(
            forKey: "soyeht.agentStateIntegration.codexScriptHash"
        ), let actualHash = AgentStateIntegrationInstaller.sha256(
            AgentStateIntegrationInstaller.codexScriptPath()
        ), expectedHash == actualHash else {
            return false
        }

        // Inline `[hooks]`/`[[hooks.*]]` tables in config.toml are hooks we do
        // not manage here: fail closed. (`[hooks.state]` is trust storage, not
        // a hook definition, and is allowed.)
        let configPath = AgentStateIntegrationInstaller.codexHome()
            .appendingPathComponent("config.toml")
        if let configText = try? String(contentsOf: configPath, encoding: .utf8) {
            if configText.contains("[[hooks.") || configText.range(
                of: #"(?m)^\s*\[hooks\]\s*$"#,
                options: .regularExpression
            ) != nil {
                return false
            }
        }

        let hooksPath = AgentStateIntegrationInstaller.codexHome()
            .appendingPathComponent("hooks.json")
        guard let data = try? Data(contentsOf: hooksPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        var foundSoyehtHook = false
        for (_, groupsValue) in hooks {
            guard let groups = groupsValue as? [[String: Any]] else { return false }
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                for handler in handlers {
                    let command = handler["command"] as? String ?? ""
                    guard command.contains(AgentStateIntegrationInstaller.markerScriptName) else {
                        return false
                    }
                    foundSoyehtHook = true
                }
            }
        }
        return foundSoyehtHook
    }
}

/// Prepares agent launch commands typed into Soyeht panes.
enum AgentLaunchCommandBuilder {
    /// Agents whose startup hook is emitted only after their first prompt.
    /// They use timed delivery, so the login shell must not survive a fast
    /// launch failure: otherwise the structured handoff can be typed into the
    /// restored shell and interpreted as commands. `exec` makes agent exit
    /// close the PTY instead of exposing that shell during the delivery race.
    private static let turnBoundExecutables: Set<String> = [
        "agy", "codex", "copilot", "devin", "grok", "kimi",
    ]

    static func supportsStartupHandshake(agentName: String?) -> Bool {
        AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: agentName)
    }

    static func prepare(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return command }
        let pieces = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard let executableToken = pieces.first else { return command }
        let unquotedExecutable = executableToken.trimmingCharacters(
            in: CharacterSet(charactersIn: "'\"")
        )
        let executable = (unquotedExecutable as NSString).lastPathComponent.lowercased()
        if executable == "devin" {
            let withExport = trimmed.contains("--export")
                ? trimmed
                : "\(trimmed) --export \"$SOYEHT_AGENT_TRANSCRIPT_PATH\""
            return exitSafeAgentCommand(withExport, executable: executable)
        }
        if executable == "codex",
           !trimmed.contains("--dangerously-bypass-hook-trust"),
           CodexHookAudit.bypassAllowed() {
            let remainder = pieces.count > 1 ? String(pieces[1]) : ""
            let withBypass = remainder.isEmpty
                ? "\(executableToken) --dangerously-bypass-hook-trust"
                : "\(executableToken) --dangerously-bypass-hook-trust \(remainder)"
            return exitSafeAgentCommand(withBypass, executable: executable)
        }
        return exitSafeAgentCommand(trimmed, executable: executable)
    }

    private static func exitSafeAgentCommand(_ command: String, executable: String) -> String {
        guard turnBoundExecutables.contains(executable) else { return command }
        return "exec \(command)"
    }
}
