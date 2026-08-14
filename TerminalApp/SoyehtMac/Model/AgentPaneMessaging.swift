import Foundation
import SoyehtCore

enum AgentPaneEnvironment {
    static let conversationIDKey = "SOYEHT_CONVERSATION_ID"
    static let handleKey = "SOYEHT_HANDLE"
    static let automationDirKey = "SOYEHT_AUTOMATION_DIR"
    static let launchNonceKey = "SOYEHT_LAUNCH_NONCE"

    static func values(
        for conversation: Conversation,
        launchNonce: String? = nil,
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
        if let launchNonce, !launchNonce.isEmpty {
            values[launchNonceKey] = launchNonce
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

/// Startup hooks are not uniformly emitted when a CLI first paints its TUI.
/// Some agents create their session only after the first submitted prompt, so
/// waiting for their SessionStart report before typing that prompt deadlocks.
enum AgentStartupHandshakePolicy {
    static let turnBoundAgents: Set<String> = [
        "agy", "antigravity", "codex", "copilot", "grok", "kimi", "devin",
    ]

    static func supportsStartupHandshake(agentName: String?) -> Bool {
        guard let agentName, !agentName.isEmpty else { return false }
        return !turnBoundAgents.contains(agentName.lowercased())
    }
}

/// Builds a durable handoff transcript across repeated in-place agent
/// switches. A full-screen TUI may replace the terminal's visible/scrollback
/// buffer, so each newly captured session is appended to the previously saved
/// handoff before the bounded tail is injected into the next agent.
enum AgentHandoffContext {
    static let maximumTranscriptLines = 400
    private static let maximumPreservedContinuityMarkers = 30
    private static let sessionSeparator = "--- NEXT AGENT SESSION ---"
    private static let injectedHistoryStart = "--- HISTÓRICO ANTERIOR ("
    private static let injectedHistoryEnd = "--- FIM DO HISTÓRICO ANTERIOR ---"

    static func accumulating(previous: String?, current: String) -> String {
        let previous = sanitizedSession(previous ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let current = sanitizedSession(current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        switch (previous.isEmpty, current.isEmpty) {
        case (true, true):
            combined = ""
        case (true, false):
            combined = current
        case (false, true):
            combined = previous
        case (false, false):
            combined = "\(previous)\n\n\(sessionSeparator)\n\(current)"
        }
        return tailLines(combined, maximumTranscriptLines)
    }

    /// Terminal screen buffers may contain NUL padding, which some agent TUIs
    /// treat as an invalid paste and discard wholesale. The current session
    /// also contains the handoff prompt we injected into that agent; remove
    /// its nested history block so repeated switches do not duplicate the
    /// entire transcript exponentially.
    static func sanitizedSession(_ text: String) -> String {
        let withoutNUL = text.replacingOccurrences(of: "\0", with: "")
        let normalizedNewlines = withoutNUL
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var historyDepth = 0
        var retained: [Substring] = []
        for line in normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains(injectedHistoryStart) {
                historyDepth += 1
                continue
            }
            if line.contains(injectedHistoryEnd), historyDepth > 0 {
                historyDepth -= 1
                continue
            }
            if historyDepth == 0 {
                retained.append(line)
            }
        }
        return retained.joined(separator: "\n")
    }

    static func prompt(
        previousAgent: String,
        transcript: String,
        additionalInstruction: String? = nil
    ) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "(sem saída de terminal capturada)" : trimmed
        var prompt = """
        Você está continuando uma conversa que estava sendo conduzida pelo agente "\(previousAgent)" neste mesmo diretório. Abaixo está o histórico anterior da conversa (transcript do terminal, incluindo comandos e saídas). Continue de onde a conversa parou, mantendo total continuidade com o que já foi discutido e feito.

        --- HISTÓRICO ANTERIOR (agente \(previousAgent)) ---
        \(body)
        --- FIM DO HISTÓRICO ANTERIOR ---

        Retome a conversa exatamente de onde parou.
        """
        if let instruction = additionalInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            prompt += """


            --- INSTRUÇÃO ADICIONAL DO HANDOFF ---
            \(instruction)
            --- FIM DA INSTRUÇÃO ADICIONAL ---
            """
        }
        return prompt
    }

    static func tailLines(_ text: String, _ maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        let markerFragments = [
            "SOYEHT_STAGE_DONE=",
            "SOYEHT_HANDOFF_TOKEN=",
            "NEXT_AGENT_MUST="
        ]
        let provisionalRetainedLineCount = max(maxLines - 1, 0)
        let provisionalDroppedLines = lines.prefix(lines.count - provisionalRetainedLineCount)
        var preservedMarkers = provisionalDroppedLines
            .filter { line in markerFragments.contains { line.contains($0) } }
            .filter { !$0.contains("SOYEHT_HANDOFF_TOKEN=") }
            .map(String.init)
        preservedMarkers.append(contentsOf: canonicalHandoffTokenMarkers(
            in: provisionalDroppedLines.joined(separator: "\n")
        ))
        preservedMarkers = Array(preservedMarkers
            .suffix(maximumPreservedContinuityMarkers)
        )
        let markerHeaderCount = preservedMarkers.isEmpty ? 0 : 1
        let retainedLineCount = max(
            maxLines - 1 - markerHeaderCount - preservedMarkers.count,
            0
        )
        let dropped = lines.count - retainedLineCount
        guard retainedLineCount > 0 else {
            return "[… \(dropped) linhas anteriores omitidas …]"
        }
        var prefix = ["[… \(dropped) linhas anteriores omitidas …]"]
        if !preservedMarkers.isEmpty {
            prefix.append("--- MARCADORES DE CONTINUIDADE PRESERVADOS ---")
            prefix.append(contentsOf: preservedMarkers)
        }
        return (prefix + lines.suffix(retainedLineCount).map(String.init))
            .joined(separator: "\n")
    }

    /// Full-screen TUIs may wrap a UUID after its third dash and paint a
    /// timestamp/status column before the continuation. Preserve a canonical
    /// one-line marker so later agents can recover the exact token even after
    /// the verbose session itself falls outside the bounded transcript tail.
    private static func canonicalHandoffTokenMarkers(in text: String) -> [String] {
        let patterns = [
            #"SOYEHT_HANDOFF_TOKEN=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#,
            #"SOYEHT_HANDOFF_TOKEN=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-)[^\n]*\n[^0-9a-fA-F\n]*([0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#
        ]
        var locatedTokens: [(location: Int, token: String)] = []
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
                    guard let range = Range(match.range(at: index), in: text) else { return nil }
                    return String(text[range])
                }
                let token = groups.joined().lowercased()
                guard token.count == 36 else { continue }
                locatedTokens.append((match.range.location, token))
            }
        }
        var tokens: [String] = []
        for located in locatedTokens.sorted(by: { $0.location < $1.location }) {
            guard !tokens.contains(located.token) else { continue }
            tokens.append(located.token)
        }
        return tokens.map { "SOYEHT_HANDOFF_TOKEN=\($0)" }
    }
}

enum AgentPaneInputPlanner {
    enum InitialPromptMode: String {
        case auto
        case message
        case raw

        init?(rawValue value: String?) {
            guard let value else {
                self = .auto
                return
            }
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            switch normalized {
            case "", "auto", "default":
                self = .auto
            case "message", "agent", "agent_message", "envelope", "enveloped":
                self = .message
            case "raw", "terminal", "literal", "input":
                self = .raw
            default:
                return nil
            }
        }

        func resolvesToMessage(for target: Conversation) -> Bool {
            switch self {
            case .auto:
                return !target.agent.isShell
            case .message:
                return true
            case .raw:
                return false
            }
        }
    }

    enum Error: Swift.Error, Equatable {
        case sourceRequired
        case cannotTargetSource(String)
        case invalidPromptMode(String)
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
            // The message is delivered as keystrokes into the destination
            // pane's stdin, and the Enter arrives as a separate key event a
            // moment later. If the text ends in an `@handle` or a path, the
            // destination agent CLI's mention-autocomplete / attachment popup
            // is still open when that Enter lands — and the CLI captures the
            // Enter to accept a fuzzy-matched file (corrupting the message) or
            // to open an attachment (message never submits). A trailing space
            // closes that popup so the Enter submits the message intact.
            // Verified against Claude Code, Codex, and opencode.
            // See docs/bug-interagent-message-input-hijack.md.
            return (submitSafeText(text), true)
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

    /// Appends a single space unless the text already ends in whitespace, so
    /// the destination CLI's last input token is never an "open" `@`/path
    /// completion when the separate Enter key arrives.
    static func submitSafeText(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return text }
        return text + " "
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

    static func initialPromptDelayMilliseconds(
        initialCommand: String?,
        explicitDelayMs: Int?
    ) -> Int {
        if let explicitDelayMs {
            return max(explicitDelayMs, 0)
        }
        let command = initialCommand?.lowercased() ?? ""
        if command.contains("codex") {
            return 8_000
        }
        if command.contains("claude") {
            return 15_000
        }
        return 1_500
    }

    static func promptAcknowledgementTimeoutSeconds(for text: String) -> TimeInterval {
        text.count > 256 || text.contains("\n") ? 20 : 8
    }

    static func terminalPastePayload(_ text: String, bracketedPasteMode: Bool) -> String {
        let isLongPaste = text.count > 256 || text.contains("\n")
        guard bracketedPasteMode, isLongPaste else { return text }
        return "\u{001B}[200~\(text)\u{001B}[201~"
    }

    private static func agentMessageEnvelope(source: Conversation, target: Conversation, text: String) -> String {
        let body = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        return "Sent via Soyeht. From: \(source.handle) (conversationID: \(source.id.uuidString)). To: \(target.handle) (conversationID: \(target.id.uuidString)). Reply via Soyeht MCP send_pane_input or message_agent to handles=[\"\(source.handle)\"] or conversationIDs=[\"\(source.id.uuidString)\"], lineEnding=enter. Request: \(body)"
    }
}
