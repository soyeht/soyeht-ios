import Foundation

/// Stable routing identity for one end of an agent-to-agent message.
///
/// Routing uses pane/workspace UUIDs. `handle` is only a human-readable
/// snapshot, deliberately stored without a leading `@` so copying an envelope
/// into a commit or GitHub comment cannot accidentally mention a real account.
struct AgentMessageEndpoint: Codable, Hashable {
    var paneID: Conversation.ID
    var workspaceID: Workspace.ID
    private(set) var handle: String

    init(paneID: Conversation.ID, workspaceID: Workspace.ID, handle: String) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.handle = Self.normalizeHandle(handle)
    }

    /// User-facing, mention-safe spelling selected for MCP 2.0 envelopes.
    var displayLabel: String { "[\(handle)]" }

    private enum CodingKeys: String, CodingKey { case paneID, workspaceID, handle }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(Conversation.ID.self, forKey: .paneID)
        workspaceID = try container.decode(Workspace.ID.self, forKey: .workspaceID)
        handle = Self.normalizeHandle(try container.decode(String.self, forKey: .handle))
    }

    private static func normalizeHandle(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? "pane" : value
    }
}

enum AgentMessageDeliveryChannel: String, Codable, Hashable {
    /// Durable, structured delivery. This channel must never write bytes to
    /// the recipient PTY.
    case semanticInbox
    /// Compatibility transport for TUIs without an out-of-band adapter. The
    /// pane layer may write the envelope only after its idle/Enter gate opens.
    case deferredTerminal
}

enum AgentMessageDeliveryPreference: String, Codable, Hashable {
    /// Prefer semantic inbox when the recipient can both wake and read it;
    /// otherwise preserve the universal deferred-terminal fallback.
    case automatic
    /// Fail closed when semantic delivery is unavailable. Never falls back to
    /// terminal input, which makes the zero-PTY guarantee explicit.
    case semanticInboxOnly
    case deferredTerminal
}

struct AgentMessageDeliveryCapabilities: Codable, Hashable {
    /// True only when an adapter/hook can wake the agent and let it read the
    /// durable inbox. Storage alone does not count as delivery.
    var canWakeAndReadSemanticInbox: Bool
    var canReceiveDeferredTerminal: Bool
    var canPresentAttention: Bool

    static let terminalOnly = AgentMessageDeliveryCapabilities(
        canWakeAndReadSemanticInbox: false,
        canReceiveDeferredTerminal: true,
        canPresentAttention: true
    )
}

struct AgentMessageDeliveryPlan: Equatable {
    enum UnavailableReason: String, Codable, Hashable {
        case semanticInboxAdapterMissing
        case deferredTerminalUnavailable
    }

    var channel: AgentMessageDeliveryChannel?
    var requestsAttention: Bool
    var unavailableReason: UnavailableReason?

    var writesToPTY: Bool { channel == .deferredTerminal }
    var isAvailable: Bool { channel != nil }

    static func resolve(
        preference: AgentMessageDeliveryPreference,
        capabilities: AgentMessageDeliveryCapabilities,
        requestsAttention: Bool
    ) -> AgentMessageDeliveryPlan {
        let attention = requestsAttention && capabilities.canPresentAttention
        switch preference {
        case .automatic:
            if capabilities.canWakeAndReadSemanticInbox {
                return AgentMessageDeliveryPlan(
                    channel: .semanticInbox,
                    requestsAttention: attention,
                    unavailableReason: nil
                )
            }
            if capabilities.canReceiveDeferredTerminal {
                return AgentMessageDeliveryPlan(
                    channel: .deferredTerminal,
                    requestsAttention: attention,
                    unavailableReason: nil
                )
            }
            return AgentMessageDeliveryPlan(
                channel: nil,
                requestsAttention: false,
                unavailableReason: .deferredTerminalUnavailable
            )

        case .semanticInboxOnly:
            guard capabilities.canWakeAndReadSemanticInbox else {
                return AgentMessageDeliveryPlan(
                    channel: nil,
                    requestsAttention: false,
                    unavailableReason: .semanticInboxAdapterMissing
                )
            }
            return AgentMessageDeliveryPlan(
                channel: .semanticInbox,
                requestsAttention: attention,
                unavailableReason: nil
            )

        case .deferredTerminal:
            guard capabilities.canReceiveDeferredTerminal else {
                return AgentMessageDeliveryPlan(
                    channel: nil,
                    requestsAttention: false,
                    unavailableReason: .deferredTerminalUnavailable
                )
            }
            return AgentMessageDeliveryPlan(
                channel: .deferredTerminal,
                requestsAttention: attention,
                unavailableReason: nil
            )
        }
    }
}

/// Tracks whether terminal input contains an unfinished draft. Both real
/// keyboard input and automation input pass through this state machine, so an
/// agent relay cannot splice itself into either kind of partially typed line.
struct AgentMessageDraftGate: Equatable {
    private(set) var pendingByteCount = 0

    var isClear: Bool { pendingByteCount == 0 }

    mutating func record(_ data: Data) {
        for byte in data {
            switch byte {
            case 0x0A, 0x0D, 0x03, 0x15: // LF/CR, Ctrl-C, Ctrl-U
                pendingByteCount = 0
            case 0x08, 0x7F: // backspace/delete
                pendingByteCount = max(0, pendingByteCount - 1)
            case 0x20...0xFF:
                pendingByteCount += 1
            default:
                break
            }
        }
    }

    mutating func record(text: String, submitsWithEnter: Bool) {
        record(Data(text.utf8))
        if submitsWithEnter {
            record(Data([0x0D]))
        }
    }
}

/// One durable semantic message. Read and acknowledgement are deliberately
/// distinct: reading exposes content; acknowledgement tells the sender that
/// the recipient accepted responsibility for it.
struct AgentMessage: Codable, Identifiable, Hashable {
    typealias ID = UUID

    var id: ID
    var sender: AgentMessageEndpoint
    var recipient: AgentMessageEndpoint
    var body: String
    var channel: AgentMessageDeliveryChannel
    var createdAt: Date
    var attentionRequestedAt: Date?
    var attentionPresentedAt: Date?
    var readAt: Date?
    var acknowledgedAt: Date?
    var deferredTerminalDeliveredAt: Date?

    init(
        id: ID = UUID(),
        sender: AgentMessageEndpoint,
        recipient: AgentMessageEndpoint,
        body: String,
        channel: AgentMessageDeliveryChannel,
        requestsAttention: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sender = sender
        self.recipient = recipient
        self.body = Self.normalizeBody(body)
        self.channel = channel
        self.createdAt = createdAt
        self.attentionRequestedAt = requestsAttention ? createdAt : nil
        self.attentionPresentedAt = nil
        self.readAt = nil
        self.acknowledgedAt = nil
        self.deferredTerminalDeliveredAt = nil
    }

    var isUnread: Bool { readAt == nil }
    var isAcknowledged: Bool { acknowledgedAt != nil }
    var needsAttention: Bool { attentionRequestedAt != nil && readAt == nil }

    private static func normalizeBody(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Per-pane durable inbox, encoded inside `Conversation` and therefore saved
/// atomically with the existing workspace snapshot.
struct AgentMessageInbox: Codable, Hashable {
    static let currentProtocolVersion = 1

    enum MutationError: Error, Equatable {
        case emptyBody
        case wrongRecipient
        case messageNotFound
        case wrongDeliveryChannel
    }

    var protocolVersion: Int = currentProtocolVersion
    private(set) var messages: [AgentMessage] = []

    var unreadCount: Int { messages.lazy.filter(\.isUnread).count }
    var unacknowledgedCount: Int { messages.lazy.filter { !$0.isAcknowledged }.count }
    var messagesNeedingAttention: [AgentMessage] { messages.filter(\.needsAttention) }
    var messagesAwaitingAttentionPresentation: [AgentMessage] {
        messages.filter { $0.needsAttention && $0.attentionPresentedAt == nil }
    }

    func message(id: AgentMessage.ID) -> AgentMessage? {
        messages.first { $0.id == id }
    }

    /// Idempotent insertion supports retries across file IPC timeouts.
    /// Returns false when this exact message ID is already present.
    @discardableResult
    mutating func enqueue(_ message: AgentMessage, recipientID: Conversation.ID) throws -> Bool {
        guard !message.body.isEmpty else { throw MutationError.emptyBody }
        guard message.recipient.paneID == recipientID else { throw MutationError.wrongRecipient }
        guard !messages.contains(where: { $0.id == message.id }) else { return false }
        messages.append(message)
        return true
    }

    mutating func markRead(_ id: AgentMessage.ID, at date: Date = Date()) throws {
        let index = try messageIndex(id)
        if messages[index].readAt == nil { messages[index].readAt = date }
    }

    mutating func acknowledge(_ id: AgentMessage.ID, at date: Date = Date()) throws {
        let index = try messageIndex(id)
        if messages[index].readAt == nil { messages[index].readAt = date }
        if messages[index].acknowledgedAt == nil { messages[index].acknowledgedAt = date }
    }

    mutating func markAttentionPresented(_ id: AgentMessage.ID, at date: Date = Date()) throws {
        let index = try messageIndex(id)
        if messages[index].attentionPresentedAt == nil {
            messages[index].attentionPresentedAt = date
        }
    }

    mutating func markDeferredTerminalDelivered(
        _ id: AgentMessage.ID,
        at date: Date = Date()
    ) throws {
        let index = try messageIndex(id)
        guard messages[index].channel == .deferredTerminal else {
            throw MutationError.wrongDeliveryChannel
        }
        if messages[index].deferredTerminalDeliveredAt == nil {
            messages[index].deferredTerminalDeliveredAt = date
        }
    }

    private func messageIndex(_ id: AgentMessage.ID) throws -> Int {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            throw MutationError.messageNotFound
        }
        return index
    }
}

/// One direction of a workspace or pane policy. Block lists use stable IDs,
/// so renaming `[caia]` does not silently remove a block.
struct AgentMessageDirectionPolicy: Codable, Hashable {
    var isEnabled: Bool
    var allowsCrossWorkspace: Bool
    var blockedWorkspaceIDs: Set<Workspace.ID>
    var blockedPaneIDs: Set<Conversation.ID>

    static let open = AgentMessageDirectionPolicy()

    init(
        isEnabled: Bool = true,
        allowsCrossWorkspace: Bool = true,
        blockedWorkspaceIDs: Set<Workspace.ID> = [],
        blockedPaneIDs: Set<Conversation.ID> = []
    ) {
        self.isEnabled = isEnabled
        self.allowsCrossWorkspace = allowsCrossWorkspace
        self.blockedWorkspaceIDs = blockedWorkspaceIDs
        self.blockedPaneIDs = blockedPaneIDs
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, allowsCrossWorkspace, blockedWorkspaceIDs, blockedPaneIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        allowsCrossWorkspace = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsCrossWorkspace
        ) ?? true
        blockedWorkspaceIDs = try container.decodeIfPresent(
            Set<Workspace.ID>.self,
            forKey: .blockedWorkspaceIDs
        ) ?? []
        blockedPaneIDs = try container.decodeIfPresent(
            Set<Conversation.ID>.self,
            forKey: .blockedPaneIDs
        ) ?? []
    }
}

/// Symmetric shape used at both workspace and pane level. Workspace and pane
/// policies compose; none can override a denial from another layer.
struct AgentCommunicationPolicy: Codable, Hashable {
    var incoming: AgentMessageDirectionPolicy
    var outgoing: AgentMessageDirectionPolicy

    static let open = AgentCommunicationPolicy()

    init(
        incoming: AgentMessageDirectionPolicy = .open,
        outgoing: AgentMessageDirectionPolicy = .open
    ) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    private enum CodingKeys: String, CodingKey { case incoming, outgoing }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        incoming = try container.decodeIfPresent(
            AgentMessageDirectionPolicy.self,
            forKey: .incoming
        ) ?? .open
        outgoing = try container.decodeIfPresent(
            AgentMessageDirectionPolicy.self,
            forKey: .outgoing
        ) ?? .open
    }
}

struct AgentMessageRoute: Hashable {
    var sender: AgentMessageEndpoint
    var recipient: AgentMessageEndpoint
}

struct AgentMessagePolicyDecision: Equatable {
    enum Denial: String, Codable, Hashable, CaseIterable {
        case sourceWorkspaceOutgoingDisabled
        case sourcePaneOutgoingDisabled
        case recipientWorkspaceIncomingDisabled
        case recipientPaneIncomingDisabled
        case sourceWorkspaceBlocksRecipientWorkspace
        case sourceWorkspaceBlocksRecipientPane
        case sourcePaneBlocksRecipientWorkspace
        case sourcePaneBlocksRecipientPane
        case recipientWorkspaceBlocksSenderWorkspace
        case recipientWorkspaceBlocksSenderPane
        case recipientPaneBlocksSenderWorkspace
        case recipientPaneBlocksSenderPane
        case sourceWorkspaceDisallowsCrossWorkspace
        case sourcePaneDisallowsCrossWorkspace
        case recipientWorkspaceDisallowsCrossWorkspace
        case recipientPaneDisallowsCrossWorkspace
    }

    var denials: [Denial]
    var isAllowed: Bool { denials.isEmpty }
}

/// Pure, deny-dominant policy evaluation. The caller supplies the four policy
/// layers from persisted Workspace/Conversation state. Every applicable block
/// is returned for audit/UI explanations; delivery is allowed only when the
/// complete list is empty.
enum AgentMessagePolicyEvaluator {
    static func evaluate(
        route: AgentMessageRoute,
        sourceWorkspacePolicy: AgentCommunicationPolicy,
        sourcePanePolicy: AgentCommunicationPolicy,
        recipientWorkspacePolicy: AgentCommunicationPolicy,
        recipientPanePolicy: AgentCommunicationPolicy
    ) -> AgentMessagePolicyDecision {
        var denials: [AgentMessagePolicyDecision.Denial] = []
        let source = route.sender
        let recipient = route.recipient
        let isCrossWorkspace = source.workspaceID != recipient.workspaceID

        evaluateOutgoing(
            sourceWorkspacePolicy.outgoing,
            disabled: .sourceWorkspaceOutgoingDisabled,
            crossWorkspace: .sourceWorkspaceDisallowsCrossWorkspace,
            blockedWorkspace: .sourceWorkspaceBlocksRecipientWorkspace,
            blockedPane: .sourceWorkspaceBlocksRecipientPane
        )
        evaluateOutgoing(
            sourcePanePolicy.outgoing,
            disabled: .sourcePaneOutgoingDisabled,
            crossWorkspace: .sourcePaneDisallowsCrossWorkspace,
            blockedWorkspace: .sourcePaneBlocksRecipientWorkspace,
            blockedPane: .sourcePaneBlocksRecipientPane
        )
        evaluateIncoming(
            recipientWorkspacePolicy.incoming,
            disabled: .recipientWorkspaceIncomingDisabled,
            crossWorkspace: .recipientWorkspaceDisallowsCrossWorkspace,
            blockedWorkspace: .recipientWorkspaceBlocksSenderWorkspace,
            blockedPane: .recipientWorkspaceBlocksSenderPane
        )
        evaluateIncoming(
            recipientPanePolicy.incoming,
            disabled: .recipientPaneIncomingDisabled,
            crossWorkspace: .recipientPaneDisallowsCrossWorkspace,
            blockedWorkspace: .recipientPaneBlocksSenderWorkspace,
            blockedPane: .recipientPaneBlocksSenderPane
        )

        return AgentMessagePolicyDecision(denials: denials)

        func evaluateOutgoing(
            _ policy: AgentMessageDirectionPolicy,
            disabled: AgentMessagePolicyDecision.Denial,
            crossWorkspace: AgentMessagePolicyDecision.Denial,
            blockedWorkspace: AgentMessagePolicyDecision.Denial,
            blockedPane: AgentMessagePolicyDecision.Denial
        ) {
            if !policy.isEnabled { denials.append(disabled) }
            if isCrossWorkspace && !policy.allowsCrossWorkspace { denials.append(crossWorkspace) }
            if policy.blockedWorkspaceIDs.contains(recipient.workspaceID) {
                denials.append(blockedWorkspace)
            }
            if policy.blockedPaneIDs.contains(recipient.paneID) { denials.append(blockedPane) }
        }

        func evaluateIncoming(
            _ policy: AgentMessageDirectionPolicy,
            disabled: AgentMessagePolicyDecision.Denial,
            crossWorkspace: AgentMessagePolicyDecision.Denial,
            blockedWorkspace: AgentMessagePolicyDecision.Denial,
            blockedPane: AgentMessagePolicyDecision.Denial
        ) {
            if !policy.isEnabled { denials.append(disabled) }
            if isCrossWorkspace && !policy.allowsCrossWorkspace { denials.append(crossWorkspace) }
            if policy.blockedWorkspaceIDs.contains(source.workspaceID) {
                denials.append(blockedWorkspace)
            }
            if policy.blockedPaneIDs.contains(source.paneID) { denials.append(blockedPane) }
        }
    }
}
