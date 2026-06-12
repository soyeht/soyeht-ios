import Foundation

enum AgentPaneEnvironment {
    static let conversationIDKey = "SOYEHT_CONVERSATION_ID"
    static let handleKey = "SOYEHT_HANDLE"

    static func values(for conversation: Conversation) -> [String: String] {
        [
            conversationIDKey: conversation.id.uuidString,
            handleKey: conversation.handle,
        ]
    }
}

enum AgentPaneInputPlanner {
    enum Error: Swift.Error, Equatable {
        case sourceRequired
        case cannotTargetSource(String)
    }

    struct Prepared: Equatable {
        let text: String
        let payload: String
        let source: Conversation?
        let envelopeApplied: Bool
        let envelopeReason: String
    }

    static func prepare(
        target: Conversation,
        source: Conversation?,
        text: String,
        appendNewline: Bool,
        lineEnding: String?,
        requestEnvelope: Bool,
        requireAgentEnvelope: Bool
    ) throws -> Prepared {
        if requireAgentEnvelope, source == nil {
            throw Error.sourceRequired
        }
        if requireAgentEnvelope, let source, source.id == target.id {
            throw Error.cannotTargetSource(source.handle)
        }

        let shouldEnvelope = requestEnvelope
            && source != nil
            && source?.id != target.id
            && target.content.isTerminal

        let outgoingText: String
        let envelopeApplied: Bool
        let envelopeReason: String
        if shouldEnvelope, let source {
            outgoingText = agentMessageEnvelope(source: source, target: target, text: text)
            envelopeApplied = true
            envelopeReason = "applied"
        } else {
            outgoingText = text
            envelopeApplied = false
            if source == nil {
                envelopeReason = requestEnvelope ? "source_unresolved" : "not_requested"
            } else if source?.id == target.id {
                envelopeReason = "self_target"
            } else if requestEnvelope, !target.content.isTerminal {
                envelopeReason = "non_terminal_target"
            } else {
                envelopeReason = "not_requested"
            }
        }

        return Prepared(
            text: outgoingText,
            payload: terminalPayload(
                text: outgoingText,
                appendNewline: appendNewline,
                lineEnding: lineEnding
            ),
            source: source,
            envelopeApplied: envelopeApplied,
            envelopeReason: envelopeReason
        )
    }

    static func terminalPayload(
        text: String,
        appendNewline: Bool,
        lineEnding: String?
    ) -> String {
        let terminator = terminalInputTerminator(lineEnding: lineEnding, appendNewline: appendNewline)
        let needsTerminator = !text.hasSuffix("\n") && !text.hasSuffix("\r")
        return text + (needsTerminator ? terminator : "")
    }

    private static func terminalInputTerminator(lineEnding: String?, appendNewline: Bool) -> String {
        guard appendNewline else { return "" }
        switch lineEnding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "false":
            return ""
        case "newline", "lf":
            return "\n"
        case "crlf":
            return "\r\n"
        default:
            return "\r"
        }
    }

    private static func agentMessageEnvelope(source: Conversation, target: Conversation, text: String) -> String {
        let body = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        return "Sent via Soyeht. From: \(source.handle) (conversationID: \(source.id.uuidString)). To: \(target.handle) (conversationID: \(target.id.uuidString)). Reply via Soyeht MCP send_pane_input or message_agent to handles=[\"\(source.handle)\"] or conversationIDs=[\"\(source.id.uuidString)\"], lineEnding=enter. Request: \(body)"
    }
}
