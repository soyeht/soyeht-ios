import CryptoKit
import Foundation

enum ConversationIntelligenceAgent: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case opencode
    case soyeht
}

enum ConversationIntelligenceLane: String, Codable, Sendable {
    /// A provider-native transcript owns the content for sessions that are not
    /// bound to a canonical Soyeht conversation.
    case native = "A"

    /// The canonical Soyeht conversation owns content when a native session ID
    /// is bound to SAHP. Native files remain useful for verification/backfill.
    case canonical = "B"
}

enum ConversationIntelligenceTurnRole: String, Codable, CaseIterable, Sendable {
    /// Structurally consistent with a user-authored prompt. This is an
    /// explicit candidate class, not a claim of perfect authorship truth.
    case humanCandidate = "human_candidate"
    case assistant
    case subagent
    case envelope
    case mcp
    case tool
    case system
    case unknown

    var isDefaultSearchContent: Bool {
        self == .humanCandidate || self == .assistant
    }
}

/// Schema-specific positive evidence emitted by an adapter. Classification is
/// intentionally fail-closed: a native role string is never sufficient to
/// declare that a person authored a turn.
enum NativeConversationTurnEvidence: String, Codable, Sendable {
    case explicitHumanText
    case explicitAssistantText
    case sidechain
    case tool
    case system
    case compacted
    case slashCommand
    case soyehtEnvelope
    case handoffTransport
    case unknown
}

struct NativeConversationDescriptor: Hashable, Sendable {
    let agent: ConversationIntelligenceAgent
    let nativeSessionID: String
    let sourceURL: URL
    let projectPath: String?
    let startedAt: Date?
    let updatedAt: Date?
    let sourceRevision: String

    /// Bump when adapter classification semantics change. This makes a parser
    /// upgrade replace the derived rows even when the provider file itself is
    /// byte-for-byte unchanged.
    var ingestRevision: String { "\(sourceRevision):ci-parser-v1" }
}

struct NativeConversationTurn: Hashable, Sendable {
    let ordinal: Int
    let nativeRole: String
    let evidence: NativeConversationTurnEvidence
    let text: String
    let timestamp: Date?
    let sourceEventID: String?
    let model: String?
    let metadata: [String: String]
}

struct NativeConversationReadResult: Sendable {
    let descriptor: NativeConversationDescriptor
    let turns: [NativeConversationTurn]
    /// Byte offset immediately after the last complete newline. A partial JSONL
    /// tail is deliberately left for the next pass.
    let nextByteOffset: Int64
    let lastCompleteLineHash: String?
    let unknownEventCount: Int
    let observedSchemaShapes: Set<ConversationSchemaObservation>
}

struct ConversationSchemaObservation: Hashable, Codable, Sendable {
    let store: String
    let schemaVersion: String
    let shape: String
}

enum ConversationSchemaManifest {
    /// Semantic schema strata supported by the adapters. Raw CLI patch
    /// versions are normalized by each adapter before reaching this manifest.
    static let declared: Set<ConversationSchemaObservation> = [
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "record:session_meta"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "record:response_item"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "record:event_msg"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "record:turn_context"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "record:compacted"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "record:world_state"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "message:user:input_text"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "message:user:input_text+input_image"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "message:assistant:output_text"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "message:system:input_text"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "message:developer:input_text"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "payload:reasoning"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "payload:function_call"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "payload:function_call_output"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "payload:custom_tool_call"),
        .init(store: "codex", schemaVersion: "response-item-v1", shape: "payload:custom_tool_call_output"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:user"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:assistant"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:system"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:progress"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:summary"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:file-history-snapshot"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:file-history-delta"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:queue-operation"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:ai-title"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:attachment"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:last-prompt"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:mode"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "record:permission-mode"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:string:human-candidate"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:text-array:human-candidate"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:tool-result"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:envelope"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:meta"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:compacted"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:slash-command"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:suggestion-accepted"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:task-notification"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:handoff-transport"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:legacy-unattributed-text"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "assistant:text"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "assistant:sidechain"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "assistant:meta"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "assistant:tool-use"),
        .init(store: "claude", schemaVersion: "jsonl-v2", shape: "assistant:control"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "message:user:text-part"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "message:assistant:text-part"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "message:assistant:compaction-text"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:tool"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:step-start"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:step-finish"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:reasoning"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:patch"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:compaction"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:file"),
        .init(store: "opencode", schemaVersion: "sqlite-v1", shape: "part:agent"),
    ]

    static func undeclared(
        in observed: Set<ConversationSchemaObservation>
    ) -> Set<ConversationSchemaObservation> {
        observed.subtracting(declared)
    }
}

struct ConversationIngestCursor: Equatable, Sendable {
    let sourceKey: String
    let sourceRevision: String
    let byteOffset: Int64
    let lastCompleteLineHash: String?
}

struct ConversationIntelligenceStats: Equatable, Sendable {
    struct AgentCount: Equatable, Sendable, Identifiable {
        let agent: String
        let conversations: Int
        let humanCandidateTurns: Int
        let assistantTurns: Int
        let excludedTurns: Int

        var id: String { agent }
    }

    let conversations: Int
    let searchableTurns: Int
    let excludedTurns: Int
    let envelopeTurns: Int
    let embeddedTurns: Int
    let pendingEmbeddingTurns: Int
    let agents: [AgentCount]
}

struct ConversationCollaborationEdge: Equatable, Sendable, Identifiable {
    let fromHandle: String
    let toHandle: String
    let messages: Int

    var id: String { "\(fromHandle)\u{1f}\(toHandle)" }
}

struct ConversationIntelligenceSearchResult: Equatable, Sendable, Identifiable {
    let turnID: String
    let conversationID: String
    let agent: String
    let role: ConversationIntelligenceTurnRole
    let projectAlias: String?
    let timestamp: Date?
    let snippet: String
    let lexicalRank: Int?
    let semanticRank: Int?
    let score: Double

    var id: String { turnID }
}

enum ConversationIntelligenceText {
    static func normalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func stableTurnID(
        agent: String,
        nativeSessionID: String,
        ordinal: Int,
        sourceEventID: String? = nil
    ) -> String {
        let sourceKey = sourceEventID.flatMap { normalize($0).isEmpty ? nil : normalize($0) }
            ?? String(ordinal)
        return sha256("\(agent)\u{1f}\(nativeSessionID)\u{1f}\(sourceKey)")
    }
}

enum ConversationEmbeddingChunker {
    static let maxCharacters = 2_400
    static let maxChunksPerTurn = 64

    /// Paragraph-aware bounded chunks keep long agent answers searchable
    /// without sending an unbounded turn to the embedding model.
    static func chunks(_ raw: String) -> [String] {
        let text = ConversationIntelligenceText.normalize(raw)
        guard !text.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""
        let paragraphs = text.components(separatedBy: "\n\n")

        func flush() {
            let normalized = ConversationIntelligenceText.normalize(current)
            if !normalized.isEmpty { chunks.append(normalized) }
            current = ""
        }

        for paragraph in paragraphs {
            if chunks.count >= maxChunksPerTurn { break }
            if paragraph.count <= maxCharacters {
                let candidate = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
                if candidate.count <= maxCharacters {
                    current = candidate
                } else {
                    flush()
                    current = paragraph
                }
                continue
            }

            flush()
            var remaining = paragraph[...]
            while !remaining.isEmpty, chunks.count < maxChunksPerTurn {
                let end = remaining.index(
                    remaining.startIndex,
                    offsetBy: min(maxCharacters, remaining.count)
                )
                chunks.append(String(remaining[..<end]))
                remaining = remaining[end...]
            }
        }
        if chunks.count < maxChunksPerTurn { flush() }
        return Array(chunks.prefix(maxChunksPerTurn))
    }
}

enum ConversationTurnClassifier {
    private static let soyehtEnvelopePrefix = "Sent via Soyeht. From:"
    private static let handoffPrefix = "SOYEHT_AGENT_HANDOFF_"

    static func classify(nativeRole: String, text rawText: String) -> ConversationIntelligenceTurnRole {
        let role = nativeRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = ConversationIntelligenceText.normalize(rawText)

        if text.hasPrefix(handoffPrefix) {
            return .mcp
        }
        if isSoyehtEnvelope(text) {
            return .envelope
        }

        switch nativeRoleEvidence(nativeRole: role, text: text) {
        case .explicitHumanText:
            return .humanCandidate
        case .explicitAssistantText:
            return .assistant
        case .sidechain:
            return .subagent
        case .tool:
            return .tool
        case .system, .compacted, .slashCommand:
            return .system
        case .handoffTransport:
            return .mcp
        case .soyehtEnvelope:
            return .envelope
        case .unknown:
            return .unknown
        }
    }

    static func classify(_ turn: NativeConversationTurn) -> ConversationIntelligenceTurnRole {
        let text = ConversationIntelligenceText.normalize(turn.text)
        if text.hasPrefix(handoffPrefix) { return .mcp }
        if isSoyehtEnvelope(text) { return .envelope }
        switch turn.evidence {
        case .explicitHumanText: return .humanCandidate
        case .explicitAssistantText: return .assistant
        case .sidechain: return .subagent
        case .tool: return .tool
        case .system, .compacted, .slashCommand: return .system
        case .soyehtEnvelope: return .envelope
        case .handoffTransport: return .mcp
        case .unknown: return .unknown
        }
    }

    /// Compatibility for canonical events whose reporter has already performed
    /// provider-specific filtering. Native adapters must call `classify(_:)`.
    private static func nativeRoleEvidence(
        nativeRole: String,
        text: String
    ) -> NativeConversationTurnEvidence {
        if text.hasPrefix(handoffPrefix) { return .handoffTransport }
        if isSoyehtEnvelope(text) { return .soyehtEnvelope }
        switch nativeRole {
        case "assistant", "agent": return .explicitAssistantText
        case "tool", "tool_use", "tool_result", "function_call", "function_call_output": return .tool
        case "system", "developer": return .system
        default: return .unknown
        }
    }

    static func isSoyehtEnvelope(_ text: String) -> Bool {
        guard text.hasPrefix(soyehtEnvelopePrefix) else { return false }
        // Requiring the routing fields makes a normal user sentence beginning
        // with the same words insufficient to disappear from their analytics.
        return text.contains("conversationID:")
            && text.contains("Reply via Soyeht MCP")
            && text.contains("Request:")
    }
}

struct SoyehtEnvelopeMetadata: Equatable, Sendable {
    let fromHandle: String
    let fromConversationID: String
    let toHandle: String
    let toConversationID: String

    static func parse(_ text: String) -> Self? {
        let pattern = #"^Sent via Soyeht\. From: ([^\s(]+) \(conversationID: ([^)]+)\)\. To: ([^\s(]+) \(conversationID: ([^)]+)\)\."#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges == 5 else { return nil }

        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            let value = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        guard let fromHandle = capture(1),
              let fromConversationID = capture(2),
              let toHandle = capture(3),
              let toConversationID = capture(4) else { return nil }
        return Self(
            fromHandle: fromHandle,
            fromConversationID: fromConversationID,
            toHandle: toHandle,
            toConversationID: toConversationID
        )
    }
}

enum ConversationTimestampParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: Any?) -> Date? {
        if let numeric = value as? Double {
            let seconds = numeric > 10_000_000_000 ? numeric / 1_000 : numeric
            return Date(timeIntervalSince1970: seconds)
        }
        if let numeric = value as? Int {
            let raw = Double(numeric)
            let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        guard let raw = value as? String else { return nil }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
