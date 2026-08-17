import Foundation
import SQLite3

struct OpenCodeConversationAdapter: ConversationSourceAdapter {
    let databaseURL: URL
    let agent: ConversationIntelligenceAgent = .opencode

    func discover(updatedSince: Date?, limit: Int?) throws -> [NativeConversationDescriptor] {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }
        try requireSchema(db)

        let sql = """
            SELECT id, directory, time_created, time_updated, version
            FROM session
            WHERE (? IS NULL OR time_updated >= ?)
            ORDER BY time_updated DESC
            LIMIT ?
            """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        if let updatedSince {
            let millis = Int64(updatedSince.timeIntervalSince1970 * 1_000)
            sqlite3_bind_int64(statement, 1, millis)
            sqlite3_bind_int64(statement, 2, millis)
        } else {
            sqlite3_bind_null(statement, 1)
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int(statement, 3, Int32(limit ?? Int(Int32.max)))

        let schemaRevision = try schemaRevision(db)
        var descriptors: [NativeConversationDescriptor] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            // The synthetic URL is an in-memory provenance identity only. It
            // is salted before persistence and is never opened or displayed.
            let sourceURL = databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent(".soyeht-opencode-sessions", isDirectory: true)
                .appendingPathComponent(id, isDirectory: false)
            descriptors.append(NativeConversationDescriptor(
                agent: agent,
                nativeSessionID: id,
                sourceURL: sourceURL,
                projectPath: text(statement, 1),
                startedAt: ConversationTimestampParser.parse(number(statement, 2)),
                updatedAt: ConversationTimestampParser.parse(number(statement, 3)),
                sourceRevision: schemaRevision
            ))
        }
        return descriptors
    }

    func read(
        _ descriptor: NativeConversationDescriptor,
        fromByteOffset: Int64
    ) throws -> NativeConversationReadResult {
        let db = try openReadOnly()
        defer { sqlite3_close(db) }
        try requireSchema(db)

        let statement = try prepare(db, """
            SELECT p.id, p.time_created, p.time_updated, p.data, m.data
            FROM part p JOIN message m ON m.id = p.message_id
            WHERE p.session_id = ? AND p.time_updated >= ?
            ORDER BY p.time_updated ASC, p.id ASC
            """)
        defer { sqlite3_finalize(statement) }
        bind(descriptor.nativeSessionID, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, max(0, fromByteOffset))

        var turns: [NativeConversationTurn] = []
        var observations: Set<ConversationSchemaObservation> = []
        var unknown = 0
        var highWater = fromByteOffset
        while sqlite3_step(statement) == SQLITE_ROW {
            let created = sqlite3_column_int64(statement, 1)
            let updated = sqlite3_column_int64(statement, 2)
            highWater = max(highWater, updated)
            guard let partJSON = text(statement, 3).flatMap(jsonObject),
                  let messageJSON = text(statement, 4).flatMap(jsonObject) else {
                unknown += 1
                continue
            }
            let partType = (partJSON["type"] as? String) ?? "unknown"
            let role = (messageJSON["role"] as? String) ?? "unknown"
            guard partType == "text", let rawText = partJSON["text"] as? String else {
                // Non-text parts stay outside content mining. Their shape is
                // represented by coverage counters rather than copied payloads.
                let knownPartTypes: Set<String> = [
                    "tool", "step-start", "step-finish", "reasoning",
                    "patch", "compaction", "file", "agent",
                ]
                let observation = ConversationSchemaObservation(
                    store: agent.rawValue,
                    schemaVersion: "sqlite-v1",
                    shape: knownPartTypes.contains(partType)
                        ? "part:\(partType)"
                        : "part:unknown"
                )
                observations.insert(observation)
                if !knownPartTypes.contains(partType) { unknown += 1 }
                continue
            }
            let normalized = ConversationIntelligenceText.normalize(rawText)
            guard !normalized.isEmpty else { continue }
            let evidence = evidence(
                role: role,
                text: normalized,
                synthetic: partJSON["synthetic"] as? Bool == true,
                agentName: messageJSON["agent"] as? String
            )
            let shape: String
            if role.lowercased() == "assistant",
               (messageJSON["agent"] as? String) == "compaction" {
                shape = "message:assistant:compaction-text"
            } else if role.lowercased() == "user" || role.lowercased() == "assistant" {
                shape = "message:\(role.lowercased()):text-part"
            } else {
                shape = "message:unknown:text-part"
            }
            let observation = ConversationSchemaObservation(
                store: agent.rawValue,
                schemaVersion: "sqlite-v1",
                shape: shape
            )
            observations.insert(observation)
            if evidence == .unknown { unknown += 1 }
            turns.append(NativeConversationTurn(
                ordinal: Int(clamping: created),
                nativeRole: role,
                evidence: evidence,
                text: normalized,
                timestamp: ConversationTimestampParser.parse(created),
                sourceEventID: text(statement, 0),
                model: modelName(messageJSON),
                metadata: [:]
            ))
        }

        return NativeConversationReadResult(
            descriptor: descriptor,
            turns: turns,
            nextByteOffset: highWater,
            lastCompleteLineHash: nil,
            unknownEventCount: unknown,
            observedSchemaShapes: observations
        )
    }

    private func evidence(
        role: String,
        text: String,
        synthetic: Bool,
        agentName: String?
    ) -> NativeConversationTurnEvidence {
        if text.hasPrefix("SOYEHT_AGENT_HANDOFF_") { return .handoffTransport }
        if ConversationTurnClassifier.isSoyehtEnvelope(text) { return .soyehtEnvelope }
        if synthetic { return .system }
        if agentName == "compaction" { return .compacted }
        switch role.lowercased() {
        case "assistant": return .explicitAssistantText
        case "user":
            if text.hasPrefix("/") || text.hasPrefix("<command-") { return .slashCommand }
            // In OpenCode, user tool results are separate `tool` parts. A text
            // part on a non-synthetic user message is the positive allowlist.
            return .explicitHumanText
        default: return .unknown
        }
    }

    private func openReadOnly() throws -> OpaquePointer {
        var db: OpaquePointer?
        let uri = "file:\(databaseURL.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ConversationSourceAdapterError.unreadableSource(agent.rawValue)
        }
        sqlite3_busy_timeout(db, 5_000)
        _ = sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
        return db
    }

    private func requireSchema(_ db: OpaquePointer) throws {
        let required: [(String, Set<String>)] = [
            ("session", ["id", "directory", "time_created", "time_updated", "version"]),
            ("message", ["id", "session_id", "data"]),
            ("part", ["id", "message_id", "session_id", "time_created", "time_updated", "data"]),
        ]
        for (table, expected) in required {
            let statement = try prepare(db, "PRAGMA table_info(\(table))")
            var found: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = text(statement, 1) { found.insert(name) }
            }
            sqlite3_finalize(statement)
            guard expected.isSubset(of: found) else {
                throw ConversationSourceAdapterError.unsupportedSchema("opencode:\(table)")
            }
        }
    }

    private func schemaRevision(_ db: OpaquePointer) throws -> String {
        let statement = try prepare(db, "PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        return "opencode-sqlite-v1:user-version-\(version)"
    }

    private func modelName(_ message: [String: Any]) -> String? {
        if let model = message["model"] as? String { return model }
        if let model = message["model"] as? [String: Any] {
            return (model["modelID"] as? String) ?? (model["id"] as? String)
        }
        return message["modelID"] as? String
    }

    private func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ConversationSourceAdapterError.unsupportedSchema("opencode:query")
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, conversationSQLiteTransientAdapter)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func number(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, column)
    }
}

private let conversationSQLiteTransientAdapter = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
