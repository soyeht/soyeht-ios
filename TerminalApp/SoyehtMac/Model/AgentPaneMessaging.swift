import Foundation
import SoyehtCore

enum AgentPaneEnvironment {
    static let conversationIDKey = "SOYEHT_CONVERSATION_ID"
    static let handleKey = "SOYEHT_HANDLE"
    static let automationDirKey = "SOYEHT_AUTOMATION_DIR"

    static func values(
        for conversation: Conversation,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profile: SoyehtInstallProfile = .current
    ) -> [String: String] {
        var values = [
            conversationIDKey: conversation.id.uuidString,
            handleKey: conversation.handle,
        ]
        if let automationDir = automationDirectoryPath(environment: environment, profile: profile) {
            values[automationDirKey] = automationDir
        }
        return values
    }

    private static func automationDirectoryPath(
        environment: [String: String],
        profile: SoyehtInstallProfile
    ) -> String? {
        if let override = AppSupportDirectory.developerEnvironmentOverride(
            automationDirKey,
            environment: environment,
            profile: profile
        ) {
            return override
        }
        if profile == .current {
            return try? AppSupportDirectory.subdirectory("Automation").path
        }
        return try? automationDirectoryPath(profile: profile)
    }

    private static func automationDirectoryPath(profile: SoyehtInstallProfile) throws -> String {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
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
        let shouldSendEnterKey: Bool
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

        let terminalInput = terminalPayload(
            text: outgoingText,
            appendNewline: appendNewline,
            lineEnding: lineEnding
        )
        return Prepared(
            text: outgoingText,
            payload: terminalInput.payload,
            shouldSendEnterKey: terminalInput.shouldSendEnterKey,
            source: source,
            envelopeApplied: envelopeApplied,
            envelopeReason: envelopeReason
        )
    }

    static func terminalPayload(
        text: String,
        appendNewline: Bool,
        lineEnding: String?
    ) -> (payload: String, shouldSendEnterKey: Bool) {
        let terminator = terminalInputTerminator(lineEnding: lineEnding, appendNewline: appendNewline)
        if case .enterKey = terminator {
            return (text, true)
        }
        let needsTerminator = !text.hasSuffix("\n") && !text.hasSuffix("\r")
        guard needsTerminator else {
            return (text, false)
        }
        switch terminator {
        case .none:
            return (text, false)
        case .text(let value):
            return (text + value, false)
        case .enterKey:
            return (text, true)
        }
    }

    private enum TerminalInputTerminator {
        case none
        case text(String)
        case enterKey
    }

    private static func terminalInputTerminator(lineEnding: String?, appendNewline: Bool) -> TerminalInputTerminator {
        guard appendNewline else { return .none }
        switch lineEnding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "false":
            return .none
        case "newline", "lf":
            return .text("\n")
        case "crlf":
            return .text("\r\n")
        default:
            return .enterKey
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
