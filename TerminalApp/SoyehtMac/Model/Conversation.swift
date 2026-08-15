import Foundation

/// Commander state for a conversation. `.mirror` means we attach to an
/// existing tmux session via WebSocket (read + reconnect behaviour lives in
/// `MacOSWebSocketTerminalView`). `.native(pid)` is a direct `NativePTY`
/// forkpty owned by this app process — it dies with the app.
/// `.engineLocal(conversationID)` is also a local agent pane (bash/claude/
/// codex/opencode), but the PTY is owned by this Mac's own embedded engine
/// (`persistentLocalPanes` flag) and attached via WebSocket like `.mirror`,
/// so the process survives an app restart/update. Unlike `.mirror`,
/// `conversationID` is never a tmux container — it is only ever resolved
/// against `POST/GET/DELETE /api/v1/terminals/local/{conversationID}` on
/// this Mac's own engine, never a remote server.
enum CommanderState: Codable, Hashable {
    case mirror(instanceID: String)
    case native(pid: Int32)
    case engineLocal(conversationID: String)
}

/// Mutable stats displayed in the sidebar detail's 4 stat cards.
struct ConversationStats: Codable, Hashable {
    var commander: String
    var seq: Int
    var tokens: Int
    var open: Int

    static let zero = ConversationStats(commander: "—", seq: 0, tokens: 0, open: 0)
}

/// Provider-neutral, user-visible conversation history used when a pane
/// changes agents. Only real user/assistant messages belong here; terminal
/// paint, tool output, reasoning, hooks, and shell commands are deliberately
/// outside the protocol.
struct AgentConversationEvent: Codable, Hashable, Identifiable {
    enum Role: String, Codable, Hashable {
        case user
        case assistant
    }

    var id: String
    var sequence: Int
    var role: Role
    var text: String
    var sourceAgent: String
    var nativeSessionID: String?
    var sourceEventID: String?
    var model: String?
    var reasoningEffort: String?
    var variant: String?
    var createdAt: Date
}

struct AgentSessionBinding: Codable, Hashable {
    var agent: String
    var nativeSessionID: String?
    var model: String?
    var reasoningEffort: String?
    var variant: String?
    /// Last canonical event delivered to this agent. Returning native sessions
    /// receive only events after this cursor instead of the full history.
    var lastImportedSequence: Int
    var updatedAt: Date
}

/// Soyeht Agent Handoff Protocol (SAHP) v1 state for one logical pane
/// conversation. It is intentionally append-only at the semantic level.
struct AgentConversationState: Codable, Hashable {
    static let currentProtocolVersion = 1

    var protocolVersion: Int = currentProtocolVersion
    var events: [AgentConversationEvent] = []
    var bindings: [String: AgentSessionBinding] = [:]
    var nextSequence: Int = 1

    var lastSequence: Int { events.last?.sequence ?? 0 }

    struct ContextPage: Equatable {
        let afterSequence: Int
        let throughSequence: Int
        let lastSequence: Int
        let hasMore: Bool
        let nextCursor: Int?
        let events: [AgentConversationEvent]
    }

    /// Returns whole semantic events so messages are never split or confused
    /// with terminal bytes. Callers can follow `nextCursor` until `hasMore`
    /// becomes false, then acknowledge the final `throughSequence`.
    func contextPage(afterSequence requestedAfter: Int, maxEvents requestedLimit: Int) -> ContextPage {
        let afterSequence = max(0, requestedAfter)
        let limit = min(50, max(1, requestedLimit))
        let pageEvents = Array(events.lazy.filter { $0.sequence > afterSequence }.prefix(limit))
        let throughSequence = pageEvents.last?.sequence ?? afterSequence
        let hasMore = events.contains { $0.sequence > throughSequence }
        return ContextPage(
            afterSequence: afterSequence,
            throughSequence: throughSequence,
            lastSequence: lastSequence,
            hasMore: hasMore,
            nextCursor: hasMore ? throughSequence : nil,
            events: pageEvents
        )
    }

    mutating func recordSession(
        agent: String,
        nativeSessionID: String?,
        model: String?,
        reasoningEffort: String?,
        variant: String?,
        at date: Date = Date()
    ) {
        let key = Self.agentKey(agent)
        var binding = bindings[key] ?? AgentSessionBinding(
            agent: key,
            nativeSessionID: nil,
            model: nil,
            reasoningEffort: nil,
            variant: nil,
            lastImportedSequence: 0,
            updatedAt: date
        )
        if let nativeSessionID = Self.nonEmpty(nativeSessionID) {
            binding.nativeSessionID = nativeSessionID
        }
        if let model = Self.nonEmpty(model) { binding.model = model }
        if let reasoningEffort = Self.nonEmpty(reasoningEffort) {
            binding.reasoningEffort = reasoningEffort
        }
        if let variant = Self.nonEmpty(variant) { binding.variant = variant }
        binding.updatedAt = date
        bindings[key] = binding
    }

    /// Inserts or updates an event from a structured provider source.
    /// Streaming providers can reuse `sourceEventID`; the newest full text
    /// replaces the partial text without creating duplicate transcript turns.
    @discardableResult
    mutating func recordEvent(
        role: AgentConversationEvent.Role,
        text rawText: String,
        sourceAgent: String,
        nativeSessionID: String? = nil,
        sourceEventID: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        variant: String? = nil,
        at date: Date = Date()
    ) -> AgentConversationEvent? {
        let text = Self.normalizeMessage(rawText)
        guard !text.isEmpty else { return nil }
        let agent = Self.agentKey(sourceAgent)
        recordSession(
            agent: agent,
            nativeSessionID: nativeSessionID,
            model: model,
            reasoningEffort: reasoningEffort,
            variant: variant,
            at: date
        )
        let binding = bindings[agent]
        let resolvedNativeSessionID = Self.nonEmpty(nativeSessionID) ?? binding?.nativeSessionID
        let resolvedModel = Self.nonEmpty(model) ?? binding?.model
        let resolvedReasoningEffort = Self.nonEmpty(reasoningEffort) ?? binding?.reasoningEffort
        let resolvedVariant = Self.nonEmpty(variant) ?? binding?.variant

        if let sourceEventID = Self.nonEmpty(sourceEventID),
           let index = events.firstIndex(where: {
               $0.sourceAgent == agent && $0.sourceEventID == sourceEventID
           }) {
            events[index].role = role
            events[index].text = text
            events[index].nativeSessionID = resolvedNativeSessionID ?? events[index].nativeSessionID
            events[index].model = resolvedModel ?? events[index].model
            events[index].reasoningEffort = resolvedReasoningEffort ?? events[index].reasoningEffort
            events[index].variant = resolvedVariant ?? events[index].variant
            return events[index]
        }

        // Some hook families emit both a display-final and a stop-final event.
        // Exact adjacent semantic duplicates are one turn, not two.
        if let last = events.last,
           last.role == role,
           last.text == text,
           last.sourceAgent == agent,
           last.nativeSessionID == resolvedNativeSessionID {
            return last
        }

        let event = AgentConversationEvent(
            id: UUID().uuidString,
            sequence: nextSequence,
            role: role,
            text: text,
            sourceAgent: agent,
            nativeSessionID: resolvedNativeSessionID,
            sourceEventID: Self.nonEmpty(sourceEventID),
            model: resolvedModel,
            reasoningEffort: resolvedReasoningEffort,
            variant: resolvedVariant,
            createdAt: date
        )
        nextSequence += 1
        events.append(event)
        return event
    }

    func eventsNotImported(by agent: String) -> [AgentConversationEvent] {
        let cursor = bindings[Self.agentKey(agent)]?.lastImportedSequence ?? 0
        return events.filter { $0.sequence > cursor }
    }

    mutating func markImported(through sequence: Int, by agent: String, at date: Date = Date()) {
        let key = Self.agentKey(agent)
        recordSession(
            agent: key,
            nativeSessionID: nil,
            model: nil,
            reasoningEffort: nil,
            variant: nil,
            at: date
        )
        guard var binding = bindings[key] else { return }
        binding.lastImportedSequence = max(binding.lastImportedSequence, sequence)
        binding.updatedAt = date
        bindings[key] = binding
    }

    private static func agentKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func normalizeMessage(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A single live or attachable conversation within a workspace.
///
/// `handle` is the user-facing `@name` token. Uniqueness is enforced by
/// `ConversationStore.add(...)` across the app — collisions auto-suffix with
/// `-2`, `-3`, etc. Keeping this namespace global makes MCP automation by
/// handle deterministic even when multiple windows/workspaces are open.
struct Conversation: Codable, Identifiable, Hashable {
    typealias ID = UUID

    var id: ID
    var handle: String
    var agent: AgentType
    var workspaceID: Workspace.ID
    var commander: CommanderState
    var content: PaneContent
    var workingDirectoryPath: String?
    /// Structured, provider-neutral conversation. Terminal scrollback is not
    /// a source for this state.
    var agentConversation: AgentConversationState
    var stats: ConversationStats
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, handle, agent, workspaceID, commander, content, workingDirectoryPath
        case agentConversation, agentHandoffTranscript, stats, createdAt
    }

    init(
        id: ID = UUID(),
        handle: String,
        agent: AgentType,
        workspaceID: Workspace.ID,
        commander: CommanderState,
        content: PaneContent = .terminal(TerminalPaneState()),
        workingDirectoryPath: String? = nil,
        agentConversation: AgentConversationState = AgentConversationState(),
        stats: ConversationStats = .zero,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.handle = handle
        self.agent = agent
        self.workspaceID = workspaceID
        self.commander = commander
        self.content = content
        self.workingDirectoryPath = workingDirectoryPath
        self.agentConversation = agentConversation
        self.stats = stats
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        handle = try container.decode(String.self, forKey: .handle)
        agent = try container.decode(AgentType.self, forKey: .agent)
        workspaceID = try container.decode(Workspace.ID.self, forKey: .workspaceID)
        commander = try container.decode(CommanderState.self, forKey: .commander)
        content = try container.decodeIfPresent(PaneContent.self, forKey: .content) ?? .terminal(TerminalPaneState())
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath)
        agentConversation = try container.decodeIfPresent(
            AgentConversationState.self,
            forKey: .agentConversation
        ) ?? AgentConversationState()
        // `agentHandoffTranscript` is intentionally decoded only for backward
        // compatibility and discarded: it was terminal paint and can contain
        // text that was never part of the conversation.
        _ = try container.decodeIfPresent(String.self, forKey: .agentHandoffTranscript)
        stats = try container.decodeIfPresent(ConversationStats.self, forKey: .stats) ?? .zero
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(handle, forKey: .handle)
        try container.encode(agent, forKey: .agent)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(commander, forKey: .commander)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(workingDirectoryPath, forKey: .workingDirectoryPath)
        try container.encode(agentConversation, forKey: .agentConversation)
        try container.encode(stats, forKey: .stats)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
