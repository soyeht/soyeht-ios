import Foundation

/// Which agent a Conversation runs. `.shell` routes to a local macOS bash PTY;
/// `.claw(name)` routes to a WebSocket terminal attached to
/// a running instance of the named Claw on the server.
///
/// Before Fase 4 this was a fixed four-case enum (`claude, codex, hermes,
/// shell`). Collapsing the three remote agents into `.claw(String)` lets
/// the EmptyPanePicker render the real set of Claws installed on the
/// server instead of a hard-coded list.
///
/// Persistence: snapshots v3 written the legacy rawValue strings
/// (`"claude"`, `"codex"`, etc.). The custom Codable below decodes any
/// unknown string as `.claw(raw)` so those snapshots load on v4 without a
/// migration sweep — the on-disk bytes are identical.
enum AgentType: Hashable, Sendable {
    case shell
    case claw(String)

    /// User-visible identifier ("shell" / claw name). Drives the pane
    /// header label and — for canonical names — the handle suffix.
    var displayName: String {
        switch self {
        case .shell: return "shell"
        case .claw(let name): return name
        }
    }

    /// Opaque string representation. Kept for call-sites that forwarded
    /// the old `rawValue` to non-Swift layers (pairing JSON, logging).
    var rawValue: String {
        switch self {
        case .shell: return "shell"
        case .claw(let name): return name
        }
    }

    var isShell: Bool {
        if case .shell = self { return true }
        return false
    }

    /// Set used by `NewConversationSheetController` when it still wants a
    /// static dropdown. The dynamic list driven by installed claws is
    /// introduced in Fase 4.2 (EmptyPaneSessionPickerView first); other
    /// call-sites migrate as their UX demands.
    static var canonicalCases: [AgentType] {
        [.shell, .claw("claude"), .claw("codex"), .claw("hermes")]
    }
}

// MARK: - Codable (backwards compatible with v3 snapshots)

extension AgentType: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "shell" ? .shell : .claw(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
