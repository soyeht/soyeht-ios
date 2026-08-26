import Foundation

/// Stable routing identity for one end of an agent-to-agent message.
///
/// Routing uses pane/workspace UUIDs. `handle` is only a human-readable
/// snapshot, deliberately stored without a leading `@` so copying an envelope
/// into a commit or GitHub comment cannot accidentally mention a real account.
struct AgentMessageEndpoint: Codable, Hashable {
    static let soyehtControlPlanePaneID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
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
    private enum EscapeState: Equatable {
        case normal
        case escape
        case singleShiftThree
        case x10MousePayload(Int)
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private(set) var pendingByteCount = 0
    private(set) var hasUncertainTerminalDraft = false
    private var escapeState: EscapeState = .normal
    private var controlSequenceBytes: [UInt8] = []
    private var isInsideBracketedPaste = false
    private var bracketedPasteEndCandidate: [UInt8] = []

    var isClear: Bool {
        pendingByteCount == 0 && !hasUncertainTerminalDraft && !isInsideBracketedPaste
    }

    /// A broker paste was admitted but its requested Return was not. The
    /// payload may itself contain LF/CR bytes that were inert inside bracketed
    /// paste, so byte parsing cannot prove the TUI composer is clear.
    mutating func markUncertainTerminalDraft() {
        hasUncertainTerminalDraft = true
        // Do not clear `isInsideBracketedPaste`: an outcome-unknown write may
        // have admitted ESC[200~ without ESC[201~. Opening the local gate
        // while the TUI still treats CR/Ctrl-C as literal paste content would
        // let the next relay splice into that composer. Recovery therefore
        // sends an explicit paste-end boundary followed by Ctrl-C.
        escapeState = .normal
        controlSequenceBytes.removeAll(keepingCapacity: true)
    }

    mutating func markSubmissionAcknowledged() {
        pendingByteCount = 0
        hasUncertainTerminalDraft = false
        isInsideBracketedPaste = false
        bracketedPasteEndCandidate.removeAll(keepingCapacity: true)
        escapeState = .normal
        controlSequenceBytes.removeAll(keepingCapacity: true)
    }

    /// Automation may move ahead of a blocked complete submission only when
    /// every byte is an explicit draft-edit/cancel control whose effect is
    /// independent of cursor position. Ctrl-U is deliberately excluded: in
    /// readline-style editors it only deletes to the cursor and can leave an
    /// invisible suffix that a later relay would submit.
    static func automationCanMutateExistingHumanDraft(
        text: String,
        isExplicitRawInput: Bool
    ) -> Bool {
        guard isExplicitRawInput else { return false }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return false }
        let safeControls: Set<UInt8> = [
            0x03, 0x08, 0x0A, 0x0D, 0x7F,
        ] // Ctrl-C, BS, explicit raw LF/CR, DEL
        return bytes.allSatisfy(safeControls.contains)
    }

    mutating func record(_ data: Data) {
        for byte in data {
            if isInsideBracketedPaste {
                let endBoundary: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
                if !bracketedPasteEndCandidate.isEmpty || byte == 0x1B {
                    bracketedPasteEndCandidate.append(byte)
                    if bracketedPasteEndCandidate == endBoundary {
                        bracketedPasteEndCandidate.removeAll(keepingCapacity: true)
                        isInsideBracketedPaste = false
                        continue
                    }
                    if endBoundary.starts(with: bracketedPasteEndCandidate) {
                        continue
                    }
                    markCursorStateUncertain()
                    let canRestart = byte == 0x1B
                    bracketedPasteEndCandidate.removeAll(keepingCapacity: true)
                    if canRestart { bracketedPasteEndCandidate.append(byte) }
                    continue
                }
                // Bracketed paste content is literal composer input. Never
                // interpret embedded CSI-u Return/Ctrl-C packets as keys.
                markCursorStateUncertain()
                continue
            }
            switch escapeState {
            case .escape:
                switch byte {
                case 0x5B:
                    controlSequenceBytes.removeAll(keepingCapacity: true)
                    escapeState = .controlSequence // ESC [
                    continue
                case 0x5D:
                    escapeState = .operatingSystemCommand // ESC ]
                    continue
                case 0x4F:
                    escapeState = .singleShiftThree // ESC O (SS3)
                    continue
                default:
                    escapeState = .normal
                    // Alt-printable input is a control chord and must not
                    // create a draft. A line/edit control following Escape,
                    // however, still has its ordinary terminal meaning; do
                    // not swallow CR/LF and leave a phantom draft forever.
                    guard [0x03, 0x08, 0x0A, 0x0D, 0x15, 0x7F].contains(byte) else {
                        markCursorStateUncertain()
                        continue
                    }
                }
            case .singleShiftThree:
                // SS3 encodes F1-F4, keypad and cursor keys as ESC O <final>.
                // The complete packet is control input and must not create a
                // phantom human draft.
                if (0x40...0x7E).contains(byte) {
                    // SS3 cursor/keypad controls can recall or mutate a TUI
                    // composer even when our byte counter was previously
                    // empty. Function keys are conservatively held too: the
                    // app cannot observe whether the TUI bound them to an
                    // edit action.
                    markCursorStateUncertain()
                    escapeState = .normal
                }
                continue
            case .x10MousePayload(let remaining):
                // Legacy X10 mouse reporting is `CSI M Cb Cx Cy`. The three
                // payload bytes may look printable, but they are terminal
                // input metadata rather than text entered in the composer.
                escapeState = remaining > 1 ? .x10MousePayload(remaining - 1) : .normal
                continue
            case .controlSequence:
                // CSI sequences end at a byte in 0x40...0x7E. Arrow, focus,
                // mouse and other terminal reports must not masquerade as an
                // unfinished printable draft. Kitty's enhanced keyboard
                // protocol is the exception: TUIs
                // such as OpenCode encode real printable keys, Return and
                // Backspace as CSI ... u, so those packets must update the
                // same draft state as their legacy byte equivalents.
                if (0x40...0x7E).contains(byte) {
                    if byte == 0x4D, controlSequenceBytes.isEmpty {
                        // X10 mouse packets end the CSI prefix with `M`, then
                        // carry three raw bytes outside the CSI grammar.
                        controlSequenceBytes.removeAll(keepingCapacity: true)
                        escapeState = .x10MousePayload(3)
                        continue
                    } else if byte == 0x75 { // Kitty keyboard packet or cursor restore.
                        if !recordKittyKey(controlSequenceBytes) {
                            markCursorStateUncertain()
                        }
                    } else if let boundary = bracketedPasteBoundary(
                        finalByte: byte, payload: controlSequenceBytes
                    ) {
                        isInsideBracketedPaste = boundary == .start
                    } else if !isBenignControlSequence(
                        finalByte: byte,
                        payload: controlSequenceBytes
                    ) {
                        // Cursor movement, mouse input and editing keys can
                        // invalidate a simple character counter. Hold relays
                        // until an unambiguous submit/cancel arrives.
                        markCursorStateUncertain()
                    }
                    controlSequenceBytes.removeAll(keepingCapacity: true)
                    escapeState = .normal
                } else {
                    controlSequenceBytes.append(byte)
                }
                continue
            case .operatingSystemCommand:
                if byte == 0x07 { // BEL terminates OSC.
                    escapeState = .normal
                } else if byte == 0x1B {
                    escapeState = .operatingSystemCommandEscape
                }
                continue
            case .operatingSystemCommandEscape:
                escapeState = byte == 0x5C ? .normal : .operatingSystemCommand
                continue
            case .normal:
                break
            }

            switch byte {
            case 0x1B:
                escapeState = .escape
            case 0x0A, 0x0D, 0x03: // LF/CR, Ctrl-C
                pendingByteCount = 0
                hasUncertainTerminalDraft = false
            case 0x15: // Ctrl-U may leave a suffix when the cursor is not at EOL.
                markCursorStateUncertain()
            case 0x08, 0x7F: // backspace/delete
                pendingByteCount = max(0, pendingByteCount - 1)
            case 0x20...0x7F, 0xC0...0xFF:
                // Count logical UTF-8 input units, not bytes. Continuation
                // bytes (0x80...0xBF) belong to the same typed scalar as the
                // leading byte, so one Backspace clears one pt-BR character.
                pendingByteCount += 1
            default:
                if byte < 0x20 {
                    markCursorStateUncertain()
                }
            }
        }
    }

    private mutating func markCursorStateUncertain() {
        hasUncertainTerminalDraft = true
    }

    private enum BracketedPasteBoundary { case start, end }

    private func bracketedPasteBoundary(
        finalByte: UInt8,
        payload: [UInt8]
    ) -> BracketedPasteBoundary? {
        guard finalByte == 0x7E,
              let value = String(bytes: payload, encoding: .ascii) else { return nil }
        if value == "200" { return .start }
        if value == "201" { return .end }
        return nil
    }

    private func isBenignControlSequence(finalByte: UInt8, payload: [UInt8]) -> Bool {
        // Focus-in/focus-out reports are terminal lifecycle metadata and
        // cannot edit the composer.
        if payload.isEmpty && (finalByte == 0x49 || finalByte == 0x4F) {
            return true
        }

        // Normal Split panes deliberately keep terminal mouse reporting on so
        // TUIs retain their native click and scroll behavior. SGR and URXVT
        // mouse reports are input metadata, not composer edits; treating a
        // click as an unknown draft would wedge deferred messages forever.
        guard finalByte == 0x4D || finalByte == 0x6D,
              let value = String(bytes: payload, encoding: .ascii) else { return false }
        let mousePayload = value.hasPrefix("<") ? String(value.dropFirst()) : value
        let fields = mousePayload.split(separator: ";", omittingEmptySubsequences: false)
        return fields.count == 3 && fields.allSatisfy { Int($0) != nil }
    }

    /// Applies one Kitty keyboard `CSI key;modifiers:event;text u` packet.
    /// Release events never change the draft. Associated text is preferred
    /// when present; otherwise the primary codepoint is counted only when no
    /// text-preventing modifier (Ctrl/Alt/Super/Hyper/Meta) is active.
    @discardableResult
    private mutating func recordKittyKey(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty,
              let payload = String(bytes: bytes, encoding: .ascii) else { return false }
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let keyField = fields.first,
              let keyCode = Int(keyField.split(separator: ":", omittingEmptySubsequences: false)[0]) else {
            // Plain `CSI u` is cursor restore, not a keyboard packet.
            return false
        }

        let modifierField = fields.count > 1 ? fields[1] : ""
        let modifierParts = modifierField.split(separator: ":", omittingEmptySubsequences: false)
        let encodedModifiers = modifierParts.first.flatMap { Int($0) } ?? 1
        let eventType = modifierParts.count > 1 ? Int(modifierParts[1]) ?? 1 : 1
        guard eventType != 3 else { return true } // release

        let rawModifiers = max(0, encodedModifiers - 1)
        let controlModifier = 1 << 2
        if rawModifiers & controlModifier != 0 {
            if keyCode == 99 || keyCode == 67 {
                pendingByteCount = 0 // Ctrl-C
                hasUncertainTerminalDraft = false
            } else {
                // Ctrl-U/W/K and cursor controls are position-sensitive.
                markCursorStateUncertain()
            }
            return true
        }

        switch keyCode {
        case 13:
            pendingByteCount = 0
            hasUncertainTerminalDraft = false
            return true
        case 8, 127:
            pendingByteCount = max(0, pendingByteCount - 1)
            return true
        case 57399...57413, 57415, 57416:
            // Kitty reports keypad digits and printable operators as private
            // functional-key codepoints rather than their visible Unicode
            // scalar. They still add exactly one composer character. Treating
            // them as unknown leaves hasUncertainTerminalDraft set forever
            // after the user visibly erases the line with Backspace.
            let textPreventingModifierMask = (1 << 1) | (1 << 2) | (1 << 3)
                | (1 << 4) | (1 << 5)
            guard rawModifiers & textPreventingModifierMask == 0 else {
                markCursorStateUncertain()
                return true
            }
            pendingByteCount += 1
            return true
        case 57414: // keypad Enter
            pendingByteCount = 0
            hasUncertainTerminalDraft = false
            return true
        default:
            break
        }

        if fields.count > 2 {
            let associatedText = fields[2]
                .split(separator: ":", omittingEmptySubsequences: true)
                .compactMap { Int($0) }
                .filter(Self.isPrintableUnicodeScalar)
            if !associatedText.isEmpty {
                pendingByteCount += associatedText.count
                return true
            }
        }

        let textPreventingModifierMask = (1 << 1) | (1 << 3) | (1 << 4) | (1 << 5)
        guard rawModifiers & textPreventingModifierMask == 0,
              Self.isPrintableUnicodeScalar(keyCode) else {
            markCursorStateUncertain()
            return true
        }
        pendingByteCount += 1
        return true
    }

    private static func isPrintableUnicodeScalar(_ value: Int) -> Bool {
        guard let scalar = UnicodeScalar(value) else { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
            && !CharacterSet.illegalCharacters.contains(scalar)
            && !CharacterSet.nonBaseCharacters.contains(scalar)
            && !(0xE000...0xF8FF).contains(value)
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
    var deferredTerminalDeliveryStartedAt: Date?
    var deferredTerminalDeliveredAt: Date?
    var mcpClientContractVersion: Int?
    var mcpClientServerVersion: String?

    init(
        id: ID = UUID(),
        sender: AgentMessageEndpoint,
        recipient: AgentMessageEndpoint,
        body: String,
        channel: AgentMessageDeliveryChannel,
        requestsAttention: Bool = true,
        createdAt: Date = Date(),
        mcpClientContractVersion: Int? = nil,
        mcpClientServerVersion: String? = nil
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
        self.deferredTerminalDeliveryStartedAt = nil
        self.deferredTerminalDeliveredAt = nil
        self.mcpClientContractVersion = mcpClientContractVersion
        self.mcpClientServerVersion = mcpClientServerVersion
    }

    var isUnread: Bool { readAt == nil }
    var isAcknowledged: Bool { acknowledgedAt != nil }
    var needsAttention: Bool { attentionRequestedAt != nil && readAt == nil }
    var isRoleAssignmentControlDelivery: Bool {
        sender.paneID == AgentMessageEndpoint.soyehtControlPlanePaneID
            && sender.handle == "soyeht-control"
    }

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
    static let completedRetentionLimit = 500
    static let completedRetentionAge: TimeInterval = 30 * 24 * 60 * 60
    static let maximumMessageBodyUTF8Bytes = 64 * 1024
    static let maximumPendingMessages = 1_000
    static let maximumPendingBodyUTF8Bytes = 8 * 1024 * 1024

    enum MutationError: Error, Equatable {
        case emptyBody
        case wrongRecipient
        case messageNotFound
        case wrongDeliveryChannel
        case bodyTooLarge
        case pendingMessageLimitReached
        case pendingByteLimitReached
    }

    var protocolVersion: Int = currentProtocolVersion
    private(set) var messages: [AgentMessage] = []

    var unreadCount: Int { messages.lazy.filter(\.isUnread).count }
    var unacknowledgedCount: Int { messages.lazy.filter { !$0.isAcknowledged }.count }
    var messagesNeedingAttention: [AgentMessage] { messages.filter(\.needsAttention) }
    var messagesAwaitingAttentionPresentation: [AgentMessage] {
        messages.filter { $0.needsAttention && $0.attentionPresentedAt == nil }
    }
    var messagesAwaitingDeferredTerminalDelivery: [AgentMessage] {
        messages.filter {
            $0.channel == .deferredTerminal
                && $0.deferredTerminalDeliveryStartedAt == nil
                && $0.deferredTerminalDeliveredAt == nil
        }
    }
    var messagesWithUncertainDeferredTerminalDelivery: [AgentMessage] {
        messages.filter {
            $0.channel == .deferredTerminal
                && $0.deferredTerminalDeliveryStartedAt != nil
                && $0.deferredTerminalDeliveredAt == nil
        }
    }
    /// A configured graph must not authorize work for a role revision that
    /// its already-running process has not observed. A terminal fallback is
    /// observed only after the authenticated submission hook marks that exact
    /// delivery. A capable client may instead acknowledge the exact durable
    /// inbox revision before terminal delivery starts; in that case ACK is the
    /// semantic observation and cancels the fallback. An older observation
    /// can never clear a newer control message.
    var hasUnobservedRoleAssignmentDelivery: Bool {
        messages.contains {
            guard $0.isRoleAssignmentControlDelivery else { return false }
            switch $0.channel {
            case .semanticInbox:
                return $0.acknowledgedAt == nil
            case .deferredTerminal:
                return $0.deferredTerminalDeliveredAt == nil
            }
        }
    }

    struct Page {
        let messages: [AgentMessage]
        let hasMore: Bool
        let nextCursor: AgentMessage.ID?
    }

    /// Produces a stable chronological page before any read/ack mutation.
    /// The caller supplies the exact response encoding cost so the page stays
    /// below the transport cap even when labels and provenance add overhead.
    func page(
        after cursor: AgentMessage.ID?,
        unreadOnly: Bool,
        maximumCount: Int,
        maximumEncodedBytes: Int,
        encodedSize: (AgentMessage) throws -> Int
    ) throws -> Page {
        let ordered = messages.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let startIndex: Int
        if let cursor {
            guard let index = ordered.firstIndex(where: { $0.id == cursor }) else {
                throw MutationError.messageNotFound
            }
            startIndex = ordered.index(after: index)
        } else {
            startIndex = ordered.startIndex
        }
        let candidates = ordered[startIndex...].filter { !unreadOnly || $0.isUnread }
        let limit = max(1, maximumCount)
        let byteLimit = max(1, maximumEncodedBytes)
        var selected: [AgentMessage] = []
        var bytes = 0
        for message in candidates {
            guard selected.count < limit else { break }
            let messageBytes = try encodedSize(message)
            if !selected.isEmpty, bytes + messageBytes > byteLimit { break }
            selected.append(message)
            bytes += messageBytes
        }
        let hasMore = candidates.count > selected.count
        return Page(
            messages: selected,
            hasMore: hasMore,
            nextCursor: hasMore ? selected.last?.id : nil
        )
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
        let bodyBytes = message.body.utf8.count
        guard bodyBytes <= Self.maximumMessageBodyUTF8Bytes else {
            throw MutationError.bodyTooLarge
        }
        let pending = messages.filter { Self.completionDate($0) == nil }
        guard pending.count < Self.maximumPendingMessages else {
            throw MutationError.pendingMessageLimitReached
        }
        let pendingBytes = pending.reduce(into: 0) { total, item in
            total += item.body.utf8.count
        }
        guard pendingBytes <= Self.maximumPendingBodyUTF8Bytes - bodyBytes else {
            throw MutationError.pendingByteLimitReached
        }
        messages.append(message)
        return true
    }

    mutating func removeUndelivered(_ id: AgentMessage.ID) throws {
        let index = try messageIndex(id)
        guard messages[index].deferredTerminalDeliveryStartedAt == nil,
              messages[index].deferredTerminalDeliveredAt == nil else { return }
        messages.remove(at: index)
    }

    mutating func markRead(_ id: AgentMessage.ID, at date: Date = Date()) throws {
        let index = try messageIndex(id)
        if messages[index].readAt == nil { messages[index].readAt = date }
    }

    mutating func acknowledge(_ id: AgentMessage.ID, at date: Date = Date()) throws {
        try acknowledge([id], at: date)
    }

    /// Validates the entire batch before mutating it, applies duplicate IDs
    /// idempotently, and prunes once after every acknowledgement is durable.
    /// Pruning inside the loop can delete a later ID and roll the whole store
    /// mutation back forever.
    mutating func acknowledge(_ ids: [AgentMessage.ID], at date: Date = Date()) throws {
        var seen: Set<AgentMessage.ID> = []
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        let indices = try uniqueIDs.map(messageIndex)
        for index in indices {
            // An explicit inbox acknowledgement is a semantic receipt. If no
            // terminal byte has crossed the at-most-once claim yet, cancel
            // that fallback by recording the channel that actually delivered
            // the message. Otherwise a capable agent can read/ack from MCP
            // and later receive the same body a second time through its PTY.
            // Once terminal delivery has started we cannot reclassify safely:
            // bytes may already be present in the TUI composer.
            if messages[index].channel == .deferredTerminal,
               messages[index].deferredTerminalDeliveryStartedAt == nil,
               messages[index].deferredTerminalDeliveredAt == nil {
                messages[index].channel = .semanticInbox
            }
            if messages[index].readAt == nil { messages[index].readAt = date }
            if messages[index].acknowledgedAt == nil { messages[index].acknowledgedAt = date }
        }
        _ = pruneCompleted(now: date)
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
        _ = pruneCompleted(now: date)
    }

    @discardableResult
    mutating func markDeferredTerminalDeliveryStarted(
        _ id: AgentMessage.ID,
        at date: Date = Date()
    ) throws -> Bool {
        let index = try messageIndex(id)
        guard messages[index].channel == .deferredTerminal else {
            throw MutationError.wrongDeliveryChannel
        }
        guard messages[index].deferredTerminalDeliveryStartedAt == nil else { return false }
        messages[index].deferredTerminalDeliveryStartedAt = date
        return true
    }

    /// Rolls back an in-memory claim when the workspace snapshot could not be
    /// persisted. No PTY byte has been written in that path, so returning the
    /// item to `awaiting` is both safe and necessary for a later retry.
    mutating func resetDeferredTerminalDeliveryStarted(_ id: AgentMessage.ID) throws {
        let index = try messageIndex(id)
        guard messages[index].channel == .deferredTerminal else {
            throw MutationError.wrongDeliveryChannel
        }
        guard messages[index].deferredTerminalDeliveredAt == nil else { return }
        messages[index].deferredTerminalDeliveryStartedAt = nil
    }

    /// Bounds snapshot growth without ever deleting work that is unread,
    /// unacknowledged, or not known to have reached the terminal.
    @discardableResult
    mutating func pruneCompleted(
        retainingNewest limit: Int = completedRetentionLimit,
        completedAfter cutoff: Date? = nil,
        now: Date = Date()
    ) -> Int {
        let cutoff = cutoff ?? now.addingTimeInterval(-Self.completedRetentionAge)
        let completed = messages.compactMap { message -> (message: AgentMessage, completedAt: Date)? in
            guard let completedAt = Self.completionDate(message) else { return nil }
            return (message, completedAt)
        }.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.message.createdAt > $1.message.createdAt
        }
        let retainedIDs = Set(completed.prefix(max(0, limit)).map(\.message.id))
        let before = messages.count
        messages.removeAll { message in
            guard let completedAt = Self.completionDate(message) else { return false }
            return completedAt < cutoff || !retainedIDs.contains(message.id)
        }
        return before - messages.count
    }

    /// Retention starts when work is actually complete, not when it first
    /// entered the inbox. A month-old pending message acknowledged today must
    /// remain observable for the normal retention window.
    private static func completionDate(_ message: AgentMessage) -> Date? {
        guard let acknowledgedAt = message.acknowledgedAt else { return nil }
        guard message.channel == .deferredTerminal else { return acknowledgedAt }
        guard let deliveredAt = message.deferredTerminalDeliveredAt else { return nil }
        return max(acknowledgedAt, deliveredAt)
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

    /// Intersects independent policy owners. A permissive value in one layer
    /// can never cancel a denial or block stored by another layer.
    static func restricting(_ policies: AgentCommunicationPolicy...) -> AgentCommunicationPolicy {
        AgentCommunicationPolicy(
            incoming: restricting(policies.map(\.incoming)),
            outgoing: restricting(policies.map(\.outgoing))
        )
    }

    private static func restricting(
        _ policies: [AgentMessageDirectionPolicy]
    ) -> AgentMessageDirectionPolicy {
        policies.reduce(.open) { result, policy in
            AgentMessageDirectionPolicy(
                isEnabled: result.isEnabled && policy.isEnabled,
                allowsCrossWorkspace: result.allowsCrossWorkspace && policy.allowsCrossWorkspace,
                blockedWorkspaceIDs: result.blockedWorkspaceIDs.union(policy.blockedWorkspaceIDs),
                blockedPaneIDs: result.blockedPaneIDs.union(policy.blockedPaneIDs)
            )
        }
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
