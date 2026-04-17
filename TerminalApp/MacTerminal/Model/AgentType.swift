import Foundation

/// Which agent a Conversation runs. Drives the CLI invoked inside the pane's
/// PTY (on the server) and the label shown in the pane header.
enum AgentType: String, Codable, CaseIterable, Hashable {
    case claude
    case codex
    case hermes
    case shell

    var displayName: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .hermes: return "hermes"
        case .shell:  return "shell"
        }
    }
}
