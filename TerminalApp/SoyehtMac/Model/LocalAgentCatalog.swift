import Foundation

/// Local coding-agent CLIs Soyeht knows how to launch in a pane. Backs the
/// pane-header agent switcher and the `switch_agent` automation request.
///
/// The catalog maps a stable agent id (also the `AgentType.claw` name used
/// in the ConversationStore) to the CLI binary that launches it.
enum LocalAgentCatalog {
    struct Agent: Identifiable, Equatable {
        /// Stable id / claw name ("claude", "cursor").
        let name: String
        /// Menu label ("Claude Code").
        let displayName: String
        /// Default launch command (binary name; flags may be appended by
        /// `AgentLaunchCommandBuilder.prepare`).
        let command: String

        var id: String { name }
    }

    static let all: [Agent] = [
        Agent(name: "claude", displayName: "Claude Code", command: "claude"),
        Agent(name: "codex", displayName: "Codex", command: "codex"),
        Agent(name: "opencode", displayName: "OpenCode", command: "opencode"),
        Agent(name: "qwen", displayName: "Qwen Code", command: "qwen"),
        Agent(name: "antigravity", displayName: "Antigravity", command: "agy"),
        Agent(name: "pi", displayName: "Pi", command: "pi"),
        Agent(name: "droid", displayName: "Droid", command: "droid"),
        Agent(name: "kilo", displayName: "Kilo Code", command: "kilo"),
        Agent(name: "cursor", displayName: "Cursor", command: "cursor-agent"),
        Agent(name: "copilot", displayName: "Copilot CLI", command: "copilot"),
        Agent(name: "grok", displayName: "Grok", command: "grok"),
        Agent(name: "kimi", displayName: "Kimi", command: "kimi"),
        Agent(name: "devin", displayName: "Devin", command: "devin"),
        Agent(name: "qoder", displayName: "Qoder", command: "qodercli"),
    ]

    /// Agents whose CLI binary can be located on this Mac.
    static func availableAgents() -> [Agent] {
        all.filter { locateBinary($0.command) != nil }
    }

    /// Resolves a catalog entry from an agent id, binary name, or display
    /// name (case-insensitive). Covers the common aliases (agy/antigravity,
    /// cursor/cursor-agent).
    static func agent(named name: String) -> Agent? {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        return all.first {
            $0.name == lowered || $0.command == lowered || $0.displayName.lowercased() == lowered
        }
    }

    /// Resolves the catalog entry backing a conversation's `AgentType`.
    /// `.shell` and unknown names return `nil`.
    static func agent(forAgentType type: AgentType) -> Agent? {
        guard !type.isShell else { return nil }
        return agent(named: type.displayName)
    }

    /// Locates an executable in the user's PATH plus the common install
    /// roots that GUI-launched apps don't always inherit (~/.local/bin,
    /// Homebrew). Returns the absolute path, or nil when not installed.
    static func locateBinary(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        if let pathValue = ProcessInfo.processInfo.environment["PATH"] {
            directories += pathValue.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }
}
