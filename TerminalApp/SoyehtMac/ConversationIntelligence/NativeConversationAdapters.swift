import Foundation

protocol ConversationSourceAdapter: Sendable {
    var agent: ConversationIntelligenceAgent { get }

    func discover(updatedSince: Date?, limit: Int?) throws -> [NativeConversationDescriptor]
    func read(
        _ descriptor: NativeConversationDescriptor,
        fromByteOffset: Int64
    ) throws -> NativeConversationReadResult
}

enum ConversationSourceAdapterError: LocalizedError {
    case unreadableSource(String)
    case unsupportedSchema(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource:
            return "A conversation history source is not readable."
        case .unsupportedSchema:
            return "A conversation history source uses an unsupported schema."
        }
    }
}

struct JSONLConversationReader: Sendable {
    /// Keep ordinary SQLite ingest transactions small enough that scans can
    /// publish progress and observe cancellation between commits. A single
    /// JSONL record may legitimately be much larger, so `read` extends one
    /// batch through that record's newline instead of stalling at this target.
    static let preferredBatchBytes = 256 * 1_024
    private static let maximumBatchBytes = 16 * 1_024 * 1_024
    struct Line: Sendable {
        let absoluteByteOffset: Int64
        let data: Data
    }

    struct Batch: Sendable {
        let lines: [Line]
        let nextByteOffset: Int64
        let lastCompleteLineHash: String?
    }

    static func read(url: URL, fromByteOffset requestedOffset: Int64) throws -> Batch {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let safeOffset = UInt64(max(0, requestedOffset)) <= size ? UInt64(max(0, requestedOffset)) : 0
        try handle.seek(toOffset: safeOffset)
        let tail = try handle.read(upToCount: maximumBatchBytes) ?? Data()

        let preferredEnd = tail.index(
            tail.startIndex,
            offsetBy: min(preferredBatchBytes, tail.count)
        )
        let finalNewline: Data.Index?
        if let newlineWithinTarget = tail[..<preferredEnd].lastIndex(of: 0x0A) {
            finalNewline = newlineWithinTarget
        } else {
            // The first record is larger than the preferred transaction size.
            // Preserve JSONL atomicity by extending through exactly that line.
            finalNewline = tail[preferredEnd...].firstIndex(of: 0x0A)
        }

        guard let finalNewline else {
            return Batch(lines: [], nextByteOffset: Int64(safeOffset), lastCompleteLineHash: nil)
        }

        let complete = tail.prefix(through: finalNewline)
        var lines: [Line] = []
        var lineStart = complete.startIndex
        var absoluteOffset = Int64(safeOffset)
        var lastHash: String?

        while lineStart < complete.endIndex,
              let newline = complete[lineStart...].firstIndex(of: 0x0A) {
            let bytes = Data(complete[lineStart..<newline])
            if !bytes.isEmpty {
                lines.append(Line(absoluteByteOffset: absoluteOffset, data: bytes))
                lastHash = ConversationIntelligenceText.sha256(
                    String(decoding: bytes, as: UTF8.self)
                )
            }
            let consumed = complete.distance(from: lineStart, to: complete.index(after: newline))
            absoluteOffset += Int64(consumed)
            lineStart = complete.index(after: newline)
        }

        return Batch(
            lines: lines,
            nextByteOffset: Int64(safeOffset) + Int64(complete.count),
            lastCompleteLineHash: lastHash
        )
    }

    static func sourceRevision(url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        let prefixHash = ConversationIntelligenceText.sha256(String(decoding: prefix, as: UTF8.self))
        return "\(inode):\(prefixHash)"
    }

    /// Verifies that the complete line immediately before a durable cursor
    /// still has the hash committed with that cursor. Appends preserve it;
    /// in-place rewrites do not, even when inode, prefix, and file length are
    /// unchanged. This closes the rewrite case that a file identity alone
    /// cannot detect.
    static func cursorMatches(
        url: URL,
        byteOffset: Int64,
        lastCompleteLineHash: String?
    ) throws -> Bool {
        guard byteOffset > 0 else { return true }
        guard let expected = lastCompleteLineHash else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard UInt64(byteOffset) <= size else { return false }

        var windowSize = min(Int64(64 * 1_024), byteOffset)
        while windowSize <= min(Int64(maximumBatchBytes), byteOffset) {
            let windowStart = byteOffset - windowSize
            try handle.seek(toOffset: UInt64(windowStart))
            guard var window = try handle.read(upToCount: Int(windowSize)),
                  window.last == 0x0A else { return false }
            window.removeLast()
            while window.last == 0x0A { window.removeLast() }
            guard !window.isEmpty else { return false }

            if let newline = window.lastIndex(of: 0x0A) {
                let line = window[window.index(after: newline)...]
                return ConversationIntelligenceText.sha256(
                    String(decoding: line, as: UTF8.self)
                ) == expected
            }
            if windowStart == 0 {
                return ConversationIntelligenceText.sha256(
                    String(decoding: window, as: UTF8.self)
                ) == expected
            }

            let maximum = min(Int64(maximumBatchBytes), byteOffset)
            guard windowSize < maximum else { return false }
            windowSize = min(maximum, windowSize * 2)
        }
        return false
    }

    static func discoverJSONLFiles(
        under root: URL,
        sourceName: String,
        updatedSince: Date?,
        limit: Int?
    ) throws -> [(url: URL, updatedAt: Date?)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else {
            // Never collapse a missing permission or missing source into an
            // apparently valid zero-conversation result. Also never put the
            // raw path in an error or log surface.
            throw ConversationSourceAdapterError.unreadableSource(sourceName)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                // The URL/error may contain a private project path. Preserve
                // only the fact that discovery was incomplete.
                enumerationFailed = true
                return false
            }
        ) else {
            throw ConversationSourceAdapterError.unreadableSource(sourceName)
        }

        var files: [(URL, Date?)] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate
            if let updatedSince, let modified, modified < updatedSince { continue }
            files.append((url, modified))
        }
        guard !enumerationFailed else {
            throw ConversationSourceAdapterError.unreadableSource(sourceName)
        }
        files.sort { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
        if let limit, limit >= 0 { return Array(files.prefix(limit)) }
        return files
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func textContent(_ raw: Any?, acceptedTypes: Set<String>) -> String {
        if let text = raw as? String {
            return ConversationIntelligenceText.normalize(text)
        }
        guard let items = raw as? [[String: Any]] else { return "" }
        let parts = items.compactMap { item -> String? in
            let type = (item["type"] as? String)?.lowercased() ?? ""
            guard acceptedTypes.contains(type) else { return nil }
            let text = (item["text"] as? String) ?? (item["content"] as? String) ?? ""
            let normalized = ConversationIntelligenceText.normalize(text)
            return normalized.isEmpty ? nil : normalized
        }
        return parts.joined(separator: "\n\n")
    }
}

struct CodexConversationAdapter: ConversationSourceAdapter {
    let rootURL: URL
    let agent: ConversationIntelligenceAgent = .codex

    func discover(updatedSince: Date?, limit: Int?) throws -> [NativeConversationDescriptor] {
        try JSONLConversationReader.discoverJSONLFiles(
            under: rootURL,
            sourceName: agent.rawValue,
            updatedSince: updatedSince,
            limit: limit
        ).compactMap { file in
            let metadata = firstSessionMetadata(in: file.url)
            let fallbackID = file.url.deletingPathExtension().lastPathComponent
            return NativeConversationDescriptor(
                agent: agent,
                nativeSessionID: metadata.id ?? fallbackID,
                sourceURL: file.url,
                projectPath: metadata.cwd,
                startedAt: metadata.timestamp,
                updatedAt: file.updatedAt,
                sourceRevision: (try? JSONLConversationReader.sourceRevision(url: file.url)) ?? fallbackID
            )
        }
    }

    func read(
        _ descriptor: NativeConversationDescriptor,
        fromByteOffset: Int64
    ) throws -> NativeConversationReadResult {
        let batch = try JSONLConversationReader.read(
            url: descriptor.sourceURL,
            fromByteOffset: fromByteOffset
        )
        var turns: [NativeConversationTurn] = []
        var unknown = 0
        var observations: Set<ConversationSchemaObservation> = []
        for line in batch.lines {
            guard let object = JSONLConversationReader.jsonObject(line.data) else {
                observations.insert(.init(
                    store: agent.rawValue,
                    schemaVersion: "response-item-v1",
                    shape: "record:invalid-json"
                ))
                unknown += 1
                continue
            }
            let eventType = (object["type"] as? String)?.lowercased() ?? "missing"
            let recordObservation = ConversationSchemaObservation(
                store: agent.rawValue,
                schemaVersion: "response-item-v1",
                shape: "record:\(eventType)"
            )
            observations.insert(recordObservation)
            guard eventType == "response_item" else {
                if !ConversationSchemaManifest.declared.contains(recordObservation) { unknown += 1 }
                continue
            }
            guard let payload = object["payload"] as? [String: Any] else {
                observations.insert(.init(
                    store: agent.rawValue,
                    schemaVersion: "response-item-v1",
                    shape: "record:malformed-response_item"
                ))
                unknown += 1
                continue
            }

            let payloadType = (payload["type"] as? String)?.lowercased() ?? "missing"
            guard payloadType == "message" else {
                let knownToolTypes: Set<String> = [
                    "function_call", "function_call_output",
                    "custom_tool_call", "custom_tool_call_output",
                    "tool_search_call", "tool_search_output",
                ]
                let isReasoning = payloadType == "reasoning"
                let isAgentMessage = payloadType == "agent_message"
                let isKnownTool = knownToolTypes.contains(payloadType)
                let shape = isReasoning || isAgentMessage || isKnownTool
                    ? "payload:\(payloadType)"
                    : "payload:unknown"
                let observation = ConversationSchemaObservation(
                    store: agent.rawValue,
                    schemaVersion: "response-item-v1",
                    shape: shape
                )
                observations.insert(observation)
                let evidence: NativeConversationTurnEvidence = isReasoning || isAgentMessage
                    ? .system
                    : (isKnownTool ? .tool : .unknown)
                if evidence == .unknown { unknown += 1 }
                let nativeEventID = (payload["id"] as? String)
                    ?? (payload["call_id"] as? String)
                turns.append(NativeConversationTurn(
                    ordinal: Int(clamping: line.absoluteByteOffset),
                    nativeRole: isReasoning || isAgentMessage ? "system" : "tool",
                    evidence: evidence,
                    text: isReasoning
                        ? "[reasoning event]"
                        : (isAgentMessage ? "[agent message]" : "[tool event]"),
                    timestamp: ConversationTimestampParser.parse(object["timestamp"]),
                    sourceEventID: nativeEventID.map { "\(payloadType):\($0)" },
                    model: nil,
                    metadata: [:]
                ))
                continue
            }

            guard let role = payload["role"] as? String else {
                observations.insert(.init(
                    store: agent.rawValue,
                    schemaVersion: "response-item-v1",
                    shape: "message:unknown-role"
                ))
                unknown += 1
                continue
            }
            let accepted: Set<String>
            let initialEvidence: NativeConversationTurnEvidence
            let primaryContentType: String
            switch role.lowercased() {
            case "user":
                accepted = ["input_text", "text"]
                primaryContentType = "input_text"
                initialEvidence = .explicitHumanText
            case "developer", "system":
                accepted = ["input_text", "text"]
                primaryContentType = "input_text"
                initialEvidence = .system
            case "assistant":
                accepted = ["output_text", "text"]
                primaryContentType = "output_text"
                initialEvidence = .explicitAssistantText
            default:
                observations.insert(.init(
                    store: agent.rawValue,
                    schemaVersion: "response-item-v1",
                    shape: "message:unknown-role"
                ))
                unknown += 1
                continue
            }

            let contentTypes = Self.contentTypes(payload["content"])
            let allowedNonTextTypes: Set<String> = role.lowercased() == "user"
                ? ["input_image"]
                : []
            let hasText = !contentTypes.intersection(accepted).isEmpty
            let hasOnlyAllowedContent = hasText
                && contentTypes.isSubset(of: accepted.union(allowedNonTextTypes))
            let evidence = hasOnlyAllowedContent ? initialEvidence : .unknown
            let text = JSONLConversationReader.textContent(payload["content"], acceptedTypes: accepted)
            let refinedEvidence = refinedEvidence(evidence, text: text)
            let shape: String
            if role.lowercased() == "user", text.hasPrefix("<environment_context>") {
                shape = "message:user:environment-context"
            } else if role.lowercased() == "user", text.hasPrefix("<user_instructions>") {
                shape = "message:user:user-instructions"
            } else {
                shape = hasOnlyAllowedContent
                    ? "message:\(role.lowercased()):\(contentTypes.contains("input_image") ? "input_text+input_image" : primaryContentType)"
                    : "message:\(role.lowercased()):unsupported-content"
            }
            observations.insert(.init(
                store: agent.rawValue,
                schemaVersion: "response-item-v1",
                shape: shape
            ))
            if evidence == .unknown { unknown += 1 }
            guard !text.isEmpty else { continue }
            turns.append(NativeConversationTurn(
                ordinal: Int(clamping: line.absoluteByteOffset),
                nativeRole: role,
                evidence: refinedEvidence,
                text: text,
                timestamp: ConversationTimestampParser.parse(object["timestamp"]),
                sourceEventID: payload["id"] as? String,
                model: nil,
                metadata: [:]
            ))
        }
        return NativeConversationReadResult(
            descriptor: descriptor,
            turns: turns,
            nextByteOffset: batch.nextByteOffset,
            lastCompleteLineHash: batch.lastCompleteLineHash,
            unknownEventCount: unknown,
            observedSchemaShapes: observations
        )
    }

    private static func contentTypes(_ content: Any?) -> Set<String> {
        if content is String { return ["text"] }
        guard let items = content as? [[String: Any]] else { return [] }
        return Set(items.compactMap { ($0["type"] as? String)?.lowercased() })
    }

    private func refinedEvidence(
        _ evidence: NativeConversationTurnEvidence,
        text: String
    ) -> NativeConversationTurnEvidence {
        guard evidence == .explicitHumanText else { return evidence }
        if text.hasPrefix("<environment_context>") || text.hasPrefix("<user_instructions>") {
            // Codex serializes harness metadata through a user-role message.
            // It is machine-authored context, never a candidate human prompt.
            return .system
        }
        if text.hasPrefix("SOYEHT_AGENT_HANDOFF_") { return .handoffTransport }
        if ConversationTurnClassifier.isSoyehtEnvelope(text) { return .soyehtEnvelope }
        if text.hasPrefix("<command-") || text.hasPrefix("/") { return .slashCommand }
        return .explicitHumanText
    }

    private func firstSessionMetadata(in url: URL) -> (id: String?, cwd: String?, timestamp: Date?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 65_536) else {
            return (nil, nil, nil)
        }
        for rawLine in prefix.split(separator: 0x0A).prefix(20) {
            guard let object = JSONLConversationReader.jsonObject(Data(rawLine)),
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else { continue }
            return (
                payload["id"] as? String,
                payload["cwd"] as? String,
                ConversationTimestampParser.parse(object["timestamp"] ?? payload["timestamp"])
            )
        }
        return (nil, nil, nil)
    }
}

struct ClaudeConversationAdapter: ConversationSourceAdapter {
    let rootURL: URL
    let agent: ConversationIntelligenceAgent = .claude

    func discover(updatedSince: Date?, limit: Int?) throws -> [NativeConversationDescriptor] {
        try JSONLConversationReader.discoverJSONLFiles(
            under: rootURL,
            sourceName: agent.rawValue,
            updatedSince: updatedSince,
            limit: limit
        ).map { file in
            let metadata = firstConversationMetadata(in: file.url)
            let fallbackID = file.url.deletingPathExtension().lastPathComponent
            let baseID = metadata.id ?? fallbackID
            let nativeSessionID: String
            if let agentID = metadata.agentID {
                nativeSessionID = "\(baseID):subagent:\(agentID)"
            } else if file.url.pathComponents.contains("subagents") {
                nativeSessionID = "\(baseID):subagent-file:\(fallbackID)"
            } else {
                nativeSessionID = baseID
            }
            return NativeConversationDescriptor(
                agent: agent,
                nativeSessionID: nativeSessionID,
                sourceURL: file.url,
                projectPath: metadata.cwd,
                startedAt: metadata.timestamp,
                updatedAt: file.updatedAt,
                sourceRevision: (try? JSONLConversationReader.sourceRevision(url: file.url)) ?? fallbackID
            )
        }
    }

    func read(
        _ descriptor: NativeConversationDescriptor,
        fromByteOffset: Int64
    ) throws -> NativeConversationReadResult {
        let batch = try JSONLConversationReader.read(
            url: descriptor.sourceURL,
            fromByteOffset: fromByteOffset
        )
        var turns: [NativeConversationTurn] = []
        var unknown = 0
        var observations: Set<ConversationSchemaObservation> = []
        for line in batch.lines {
            guard let object = JSONLConversationReader.jsonObject(line.data) else {
                observations.insert(.init(
                    store: agent.rawValue,
                    schemaVersion: "jsonl-v2",
                    shape: "record:invalid-json"
                ))
                unknown += 1
                continue
            }
            let eventType = (object["type"] as? String)?.lowercased() ?? "missing"
            let recordObservation = ConversationSchemaObservation(
                store: agent.rawValue,
                schemaVersion: "jsonl-v2",
                shape: "record:\(eventType)"
            )
            observations.insert(recordObservation)
            guard eventType == "user" || eventType == "assistant" else {
                if !ConversationSchemaManifest.declared.contains(recordObservation) { unknown += 1 }
                continue
            }
            guard let message = object["message"] as? [String: Any] else {
                observations.insert(.init(
                    store: agent.rawValue,
                    schemaVersion: "jsonl-v2",
                    shape: "record:malformed-\(eventType)"
                ))
                unknown += 1
                continue
            }
            let role = (message["role"] as? String) ?? eventType
            let content = message["content"]
            let text = JSONLConversationReader.textContent(content, acceptedTypes: ["text"])
            let evidence = claudeEvidence(object: object, role: role, content: content, text: text)
            observations.insert(claudeObservation(
                object: object,
                role: role,
                content: content,
                evidence: evidence
            ))
            if evidence == .unknown { unknown += 1 }
            // Preserve excluded event counts without retaining tool payloads.
            let storedText: String
            if !text.isEmpty {
                storedText = text
            } else if evidence == .tool {
                storedText = "[tool result]"
            } else if evidence != .explicitHumanText && evidence != .explicitAssistantText {
                storedText = "[excluded control event]"
            } else {
                storedText = ""
            }
            guard !storedText.isEmpty else { continue }
            turns.append(NativeConversationTurn(
                ordinal: Int(clamping: line.absoluteByteOffset),
                nativeRole: role,
                evidence: evidence,
                text: storedText,
                timestamp: ConversationTimestampParser.parse(object["timestamp"]),
                sourceEventID: (object["uuid"] as? String) ?? (message["id"] as? String),
                model: message["model"] as? String,
                metadata: [:]
            ))
        }
        return NativeConversationReadResult(
            descriptor: descriptor,
            turns: turns,
            nextByteOffset: batch.nextByteOffset,
            lastCompleteLineHash: batch.lastCompleteLineHash,
            unknownEventCount: unknown,
            observedSchemaShapes: observations
        )
    }

    private func claudeObservation(
        object: [String: Any],
        role: String,
        content: Any?,
        evidence: NativeConversationTurnEvidence
    ) -> ConversationSchemaObservation {
        let shape: String
        switch (role.lowercased(), evidence) {
        case ("assistant", .sidechain): shape = "assistant:sidechain"
        case ("assistant", .explicitAssistantText): shape = "assistant:text"
        case ("assistant", .system): shape = "assistant:meta"
        case ("assistant", .tool): shape = "assistant:tool-use"
        case ("assistant", .compacted): shape = "assistant:control"
        case ("user", .tool): shape = "user:tool-result"
        case ("user", .sidechain): shape = "user:sidechain"
        case ("user", .soyehtEnvelope): shape = "user:envelope"
        case ("user", .handoffTransport): shape = "user:handoff-transport"
        case ("user", .compacted): shape = "user:compacted"
        case ("user", .slashCommand): shape = "user:slash-command"
        case ("user", .system):
            if object["isMeta"] as? Bool == true {
                shape = "user:meta"
            } else if object["promptSource"] as? String == "suggestion_accepted" {
                shape = "user:suggestion-accepted"
            } else if (object["origin"] as? [String: Any])?["kind"] as? String == "task-notification" {
                shape = "user:task-notification"
            } else {
                shape = "user:unknown-shape"
            }
        case ("user", .explicitHumanText):
            shape = content is String
                ? "user:string:human-candidate"
                : "user:text-array:human-candidate"
        case ("user", .unknown):
            let promptSource = object["promptSource"] as? String
            let originKind = (object["origin"] as? [String: Any])?["kind"] as? String
            if promptSource == "sdk" {
                // SDK-originated text is a known input channel but lacks
                // proof of human authorship, so it remains excluded.
                shape = "user:sdk-input"
            } else if promptSource == "typed", originKind == nil {
                shape = "user:typed-unattributed"
            } else {
                let noAttribution = promptSource == nil && originKind == nil
                let textOnly = content is String || ((content as? [[String: Any]])?.allSatisfy {
                    ($0["type"] as? String) == "text"
                } == true)
                shape = noAttribution && textOnly
                    ? "user:legacy-unattributed-text"
                    : "user:unknown-shape"
            }
        case ("assistant", _): shape = "assistant:unknown-shape"
        default:
            let noAttribution = object["promptSource"] == nil && object["origin"] == nil
            let textOnly = content is String || ((content as? [[String: Any]])?.allSatisfy {
                ($0["type"] as? String) == "text"
            } == true)
            shape = noAttribution && textOnly
                ? "user:legacy-unattributed-text"
                : "user:unknown-shape"
        }
        return .init(store: agent.rawValue, schemaVersion: "jsonl-v2", shape: shape)
    }

    private func claudeEvidence(
        object: [String: Any],
        role: String,
        content: Any?,
        text: String
    ) -> NativeConversationTurnEvidence {
        if text.hasPrefix("SOYEHT_AGENT_HANDOFF_") { return .handoffTransport }
        if ConversationTurnClassifier.isSoyehtEnvelope(text) { return .soyehtEnvelope }
        if object["isSidechain"] as? Bool == true { return .sidechain }
        if object["isMeta"] as? Bool == true { return .system }
        if object["isCompactSummary"] as? Bool == true { return .compacted }
        if object["toolUseResult"] != nil { return .tool }

        if let items = content as? [[String: Any]],
           items.contains(where: { ($0["type"] as? String) == "tool_result" }) {
            return .tool
        }

        if role.lowercased() == "assistant",
           let items = content as? [[String: Any]],
           text.isEmpty {
            let types = Set(items.compactMap { $0["type"] as? String })
            if types.contains("tool_use") { return .tool }
            if !types.isEmpty, types.isSubset(of: ["thinking", "fallback"]) {
                return .compacted
            }
        }

        switch role.lowercased() {
        case "assistant":
            return text.isEmpty ? .unknown : .explicitAssistantText
        case "user":
            guard !text.isEmpty else { return .unknown }
            if text.hasPrefix("<command-") || text.hasPrefix("/") { return .slashCommand }

            if (object["origin"] as? [String: Any])?["kind"] as? String == "task-notification" {
                return .system
            }

            if object["promptSource"] as? String == "suggestion_accepted" {
                // Human-initiated, but not human-authored. It must not appear
                // in the human-candidate numerator.
                return .system
            }

            let promptSource = object["promptSource"] as? String
            let originKind = (object["origin"] as? [String: Any])?["kind"] as? String
            let structurallyHuman = ["typed", "queued"].contains(promptSource)
                && originKind == "human"
                && object["isMeta"] as? Bool != true

            // `origin.kind == human` means the prompt entered through the
            // human-input path, not that a person authored it. Soyeht agent
            // envelopes use the same path. This textual deny check is an
            // irreducible part of the positive conjunction, not a fallback.
            guard structurallyHuman else { return .unknown }

            let hasAllowedShape: Bool
            if content is String {
                hasAllowedShape = true
            } else if let items = content as? [[String: Any]], !items.isEmpty {
                hasAllowedShape = items.allSatisfy { ($0["type"] as? String) == "text" }
            } else {
                hasAllowedShape = false
            }
            return hasAllowedShape ? .explicitHumanText : .unknown
        default:
            return .unknown
        }
    }

    private func firstConversationMetadata(
        in url: URL
    ) -> (id: String?, agentID: String?, cwd: String?, timestamp: Date?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (nil, nil, nil, nil)
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 65_536) else {
            return (nil, nil, nil, nil)
        }
        var id: String?
        var agentID: String?
        var cwd: String?
        var timestamp: Date?
        for rawLine in prefix.split(separator: 0x0A).prefix(50) {
            guard let object = JSONLConversationReader.jsonObject(Data(rawLine)) else { continue }
            id = id ?? (object["sessionId"] as? String)
            agentID = agentID ?? (object["agentId"] as? String)
            cwd = cwd ?? (object["cwd"] as? String)
            timestamp = timestamp ?? ConversationTimestampParser.parse(object["timestamp"])
        }
        return (id, agentID, cwd, timestamp)
    }
}
