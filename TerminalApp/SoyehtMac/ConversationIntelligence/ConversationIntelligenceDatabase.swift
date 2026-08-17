import Foundation
import SQLite3

enum ConversationIntelligenceDatabaseError: LocalizedError {
    case open(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .open: return "Could not open the private conversation intelligence database."
        case .sqlite: return "The private conversation intelligence database could not complete an operation."
        }
    }
}

private let conversationSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A small purpose-built SQLite boundary. All access is serialized by a lock;
/// callers may freely use it from ingestion, embedding, and SwiftUI tasks.
final class ConversationIntelligenceDatabase: @unchecked Sendable {
    struct PendingEmbedding: Sendable {
        let turnID: String
        let text: String
    }

    struct StoredEmbedding: Sendable {
        let turnID: String
        let chunkIndex: Int
        let vector: [Float]
    }

    struct SemanticCandidate: Sendable {
        let turnID: String
        let vector: [Float]
    }

    private let lock = NSRecursiveLock()
    private let identitySalt: Data
    private var connection: OpaquePointer?

    init(url: URL, identitySalt: Data? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.identitySalt = try identitySalt
            ?? ConversationIntelligencePrivacy.loadOrCreateInstallationSalt(
                in: url.deletingLastPathComponent()
            )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw ConversationIntelligenceDatabaseError.open(message)
        }
        connection = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA synchronous=NORMAL")
        try migrate()
        try ConversationIntelligencePrivacy.hardenStoragePermissions(databaseURL: url)
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    func cursor(for sourceURL: URL) throws -> ConversationIngestCursor? {
        try withLock {
            let sourceKey = self.sourceKey(sourceURL)
            let statement = try prepare("""
                SELECT source_revision, byte_offset, last_line_hash
                FROM ingest_state WHERE source_key = ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(sourceKey, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return ConversationIngestCursor(
                sourceKey: sourceKey,
                sourceRevision: text(statement, 0) ?? "",
                byteOffset: sqlite3_column_int64(statement, 1),
                lastCompleteLineHash: text(statement, 2)
            )
        }
    }

    /// Upserts a complete incremental batch atomically with its cursor. A
    /// source revision change replaces that conversation's turns instead of
    /// appending a second copy.
    @discardableResult
    func ingest(
        _ result: NativeConversationReadResult,
        replacingExistingSource: Bool = false
    ) throws -> Int {
        try withLock {
            try transaction {
                let descriptor = result.descriptor
                let conversationID = Self.conversationID(descriptor)
                let previous = try cursor(for: descriptor.sourceURL)
                if let previous,
                   replacingExistingSource
                    || previous.sourceRevision != descriptor.ingestRevision
                    || result.nextByteOffset < previous.byteOffset {
                    try deleteTurns(conversationID: conversationID)
                }

                try upsertConversation(descriptor, conversationID: conversationID)
                var changed = 0
                for turn in result.turns {
                    let role = ConversationTurnClassifier.classify(turn)
                    let turnID = ConversationIntelligenceText.stableTurnID(
                        agent: descriptor.agent.rawValue,
                        nativeSessionID: descriptor.nativeSessionID,
                        ordinal: turn.ordinal,
                        sourceEventID: turn.sourceEventID
                    )
                    changed += try upsertTurn(
                        id: turnID,
                        conversationID: conversationID,
                        turn: turn,
                        role: role
                    )
                }
                try upsertCursor(
                    sourceKey: sourceKey(descriptor.sourceURL),
                    revision: descriptor.ingestRevision,
                    offset: result.nextByteOffset,
                    lastLineHash: result.lastCompleteLineHash,
                    unknownEvents: result.unknownEventCount
                )
                try recordSchemaObservations(result.observedSchemaShapes)
                return changed
            }
        }
    }

    func stats() throws -> ConversationIntelligenceStats {
        try withLock {
            let totals = try singleRow("""
                SELECT
                    (SELECT COUNT(*) FROM conversations),
                    SUM(CASE WHEN role IN ('human_candidate','assistant') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN role NOT IN ('human_candidate','assistant') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN role IN ('human_candidate','assistant') AND EXISTS (
                        SELECT 1 FROM embeddings e
                        WHERE e.turn_id = turns.id
                          AND (e.model, e.model_digest, e.dimensions) = (
                              SELECT latest.model, latest.model_digest, latest.dimensions
                              FROM embeddings latest
                              ORDER BY latest.created_at DESC LIMIT 1
                          )
                    ) THEN 1 ELSE 0 END),
                    SUM(CASE WHEN role = 'envelope' THEN 1 ELSE 0 END)
                FROM turns
                """)
            let searchable = totals[safe: 1] ?? 0
            let embedded = totals[safe: 3] ?? 0

            let statement = try prepare("""
                SELECT c.agent,
                       COUNT(DISTINCT c.id),
                       SUM(CASE WHEN t.role = 'human_candidate' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN t.role = 'assistant' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN t.role NOT IN ('human_candidate','assistant') THEN 1 ELSE 0 END)
                FROM conversations c LEFT JOIN turns t ON t.conversation_id = c.id
                GROUP BY c.agent
                ORDER BY COUNT(t.id) DESC, c.agent ASC
                """)
            defer { sqlite3_finalize(statement) }
            var agents: [ConversationIntelligenceStats.AgentCount] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                agents.append(.init(
                    agent: text(statement, 0) ?? "unknown",
                    conversations: Int(sqlite3_column_int64(statement, 1)),
                    humanCandidateTurns: Int(sqlite3_column_int64(statement, 2)),
                    assistantTurns: Int(sqlite3_column_int64(statement, 3)),
                    excludedTurns: Int(sqlite3_column_int64(statement, 4))
                ))
            }
            return ConversationIntelligenceStats(
                conversations: totals[safe: 0] ?? 0,
                searchableTurns: searchable,
                excludedTurns: totals[safe: 2] ?? 0,
                envelopeTurns: totals[safe: 4] ?? 0,
                embeddedTurns: embedded,
                pendingEmbeddingTurns: max(0, searchable - embedded),
                agents: agents
            )
        }
    }

    func collaborationEdges(limit: Int = 20) throws -> [ConversationCollaborationEdge] {
        try withLock {
            let statement = try prepare("""
                SELECT from_handle, to_handle, COUNT(*)
                FROM envelope_edges
                GROUP BY from_handle, to_handle
                ORDER BY COUNT(*) DESC, from_handle, to_handle
                LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [ConversationCollaborationEdge] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let from = text(statement, 0), let to = text(statement, 1) else { continue }
                result.append(.init(
                    fromHandle: from,
                    toHandle: to,
                    messages: Int(sqlite3_column_int64(statement, 2))
                ))
            }
            return result
        }
    }

    /// Removes every derived surface for one source. Dashboard counts are
    /// queried live rather than materialized, so there is no stale aggregate
    /// table left behind after this transaction.
    func removeSource(_ sourceURL: URL) throws {
        try withLock {
            try transaction {
                let key = sourceKey(sourceURL)
                try execute(
                    """
                    DELETE FROM turn_fts WHERE rowid IN (
                        SELECT r.fts_rowid
                        FROM turn_fts_rows r
                        JOIN turns t ON t.id = r.turn_id
                        JOIN conversations c ON c.id = t.conversation_id
                        WHERE c.source_key = ?
                    )
                    """,
                    bindings: [key]
                )
                try execute("DELETE FROM conversations WHERE source_key=?", bindings: [key])
                try execute("DELETE FROM ingest_state WHERE source_key=?", bindings: [key])
            }
        }
    }

    func clearAll() throws {
        try withLock {
            try transaction {
                try execute("DELETE FROM turn_fts")
                try execute("DELETE FROM conversations")
                try execute("DELETE FROM ingest_state")
                try execute("DELETE FROM observed_schema_shapes")
            }
        }
    }

    func undeclaredSchemaObservations() throws -> Set<ConversationSchemaObservation> {
        try withLock {
            let statement = try prepare("""
                SELECT store, schema_version, shape FROM observed_schema_shapes
                WHERE is_declared = 0
                """)
            defer { sqlite3_finalize(statement) }
            var result: Set<ConversationSchemaObservation> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let store = text(statement, 0),
                      let version = text(statement, 1),
                      let shape = text(statement, 2) else { continue }
                result.insert(.init(store: store, schemaVersion: version, shape: shape))
            }
            return result
        }
    }

    func lexicalSearch(_ query: String, limit: Int) throws -> [ConversationIntelligenceSearchResult] {
        try withLock {
            let expression = Self.ftsExpression(query)
            guard !expression.isEmpty else { return [] }
            let statement = try prepare("""
                SELECT t.id, t.conversation_id, c.agent, t.role, c.project_alias,
                       t.timestamp, snippet(turn_fts, 1, '', '', ' … ', 24), bm25(turn_fts)
                FROM turn_fts
                JOIN turns t ON t.id = turn_fts.turn_id
                JOIN conversations c ON c.id = t.conversation_id
                WHERE turn_fts MATCH ? AND t.role IN ('human_candidate','assistant')
                ORDER BY bm25(turn_fts) LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(expression, at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(max(1, limit)))
            var results: [ConversationIntelligenceSearchResult] = []
            var rank = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                rank += 1
                results.append(searchResult(statement: statement, lexicalRank: rank, semanticRank: nil))
            }
            return results
        }
    }

    func pendingEmbeddings(
        model: String,
        modelDigest: String,
        dimensions: Int,
        limit: Int
    ) throws -> [PendingEmbedding] {
        try withLock {
            let statement = try prepare("""
                SELECT t.id, t.content_text
                FROM turns t
                LEFT JOIN embeddings e
                  ON e.turn_id = t.id AND e.model = ? AND e.model_digest = ? AND e.dimensions = ?
                WHERE t.role IN ('human_candidate','assistant') AND e.turn_id IS NULL
                ORDER BY COALESCE(t.timestamp, 0) DESC, t.id
                LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(model, at: 1, in: statement)
            bind(modelDigest, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(dimensions))
            sqlite3_bind_int(statement, 4, Int32(max(1, limit)))
            var result: [PendingEmbedding] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0), let content = text(statement, 1) else { continue }
                result.append(PendingEmbedding(turnID: id, text: content))
            }
            return result
        }
    }

    func pendingEmbeddingCount(
        model: String,
        modelDigest: String,
        dimensions: Int
    ) throws -> Int {
        try withLock {
            let statement = try prepare("""
                SELECT COUNT(*)
                FROM turns t
                WHERE t.role IN ('human_candidate','assistant')
                  AND NOT EXISTS (
                      SELECT 1 FROM embeddings e
                      WHERE e.turn_id = t.id
                        AND e.model = ?
                        AND e.model_digest = ?
                        AND e.dimensions = ?
                  )
                """)
            defer { sqlite3_finalize(statement) }
            bind(model, at: 1, in: statement)
            bind(modelDigest, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(dimensions))
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func storeEmbeddings(
        _ embeddings: [StoredEmbedding],
        model: String,
        modelDigest: String,
        dimensions: Int
    ) throws {
        try withLock {
            try transaction {
                let statement = try prepare("""
                    INSERT INTO embeddings(
                        turn_id, chunk_index, model, model_digest,
                        dimensions, vector, created_at
                    ) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(turn_id, chunk_index, model, model_digest, dimensions)
                    DO UPDATE SET vector=excluded.vector, created_at=excluded.created_at
                    """)
                defer { sqlite3_finalize(statement) }
                for turnID in Set(embeddings.map(\.turnID)) {
                    try execute(
                        "DELETE FROM embeddings WHERE turn_id=? AND model=? AND model_digest=? AND dimensions=?",
                        bindings: [turnID, model, modelDigest, String(dimensions)]
                    )
                }
                for item in embeddings {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(item.turnID, at: 1, in: statement)
                    sqlite3_bind_int(statement, 2, Int32(item.chunkIndex))
                    bind(model, at: 3, in: statement)
                    bind(modelDigest, at: 4, in: statement)
                    sqlite3_bind_int(statement, 5, Int32(dimensions))
                    let data = Self.encode(item.vector)
                    _ = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), conversationSQLiteTransient)
                    }
                    sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
                    try stepDone(statement)
                }
            }
        }
    }

    func semanticCandidates(
        model: String,
        modelDigest: String,
        dimensions: Int,
        limit: Int
    ) throws -> [SemanticCandidate] {
        try withLock {
            let statement = try prepare("""
                SELECT e.turn_id, e.vector
                FROM embeddings e JOIN turns t ON t.id = e.turn_id
                WHERE e.model = ? AND e.model_digest = ? AND e.dimensions = ?
                ORDER BY COALESCE(t.timestamp, 0) DESC, e.turn_id LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(model, at: 1, in: statement)
            bind(modelDigest, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(dimensions))
            sqlite3_bind_int(statement, 4, Int32(max(1, limit)))
            var items: [SemanticCandidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0),
                      let vector = blob(statement, 1).flatMap(Self.decode) else { continue }
                items.append(SemanticCandidate(turnID: id, vector: vector))
            }
            return items
        }
    }

    /// Streams the complete vector space and keeps only one score per turn.
    /// This avoids both the old 50k recency cutoff (which made old history
    /// semantically invisible) and materializing every 512-float vector in a
    /// single Swift array.
    func semanticBestScores(
        queryVector: [Float],
        model: String,
        modelDigest: String,
        dimensions: Int
    ) throws -> [String: Double] {
        try withLock {
            let statement = try prepare("""
                SELECT turn_id, vector FROM embeddings
                WHERE model = ? AND model_digest = ? AND dimensions = ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(model, at: 1, in: statement)
            bind(modelDigest, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(dimensions))
            var best: [String: Double] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let turnID = text(statement, 0),
                      let vector = blob(statement, 1).flatMap(Self.decode) else { continue }
                let score = Self.cosine(queryVector, vector)
                best[turnID] = max(best[turnID] ?? -.infinity, score)
            }
            return best
        }
    }

    func searchResults(turnIDs: [String]) throws -> [String: ConversationIntelligenceSearchResult] {
        try withLock {
            guard !turnIDs.isEmpty else { return [:] }
            let placeholders = Array(repeating: "?", count: turnIDs.count).joined(separator: ",")
            let statement = try prepare("""
                SELECT t.id, t.conversation_id, c.agent, t.role, c.project_alias,
                       t.timestamp, substr(t.content_text, 1, 600), 0.0
                FROM turns t JOIN conversations c ON c.id = t.conversation_id
                WHERE t.id IN (\(placeholders))
                """)
            defer { sqlite3_finalize(statement) }
            for (index, id) in turnIDs.enumerated() { bind(id, at: Int32(index + 1), in: statement) }
            var results: [String: ConversationIntelligenceSearchResult] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let result = searchResult(statement: statement, lexicalRank: nil, semanticRank: nil)
                results[result.turnID] = result
            }
            return results
        }
    }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS conversations(
                id TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                lane_owner TEXT NOT NULL DEFAULT 'A',
                native_session_id TEXT NOT NULL,
                soyeht_conversation_id TEXT,
                source_key TEXT NOT NULL UNIQUE,
                project_key TEXT,
                project_alias TEXT,
                started_at REAL,
                updated_at REAL,
                source_revision TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS conversations_agent_idx ON conversations(agent);
            CREATE INDEX IF NOT EXISTS conversations_native_idx ON conversations(agent, native_session_id);

            CREATE TABLE IF NOT EXISTS turns(
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                role TEXT NOT NULL,
                native_role TEXT NOT NULL,
                content_text TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                timestamp REAL,
                source_event_id TEXT,
                model TEXT
            );
            CREATE INDEX IF NOT EXISTS turns_conversation_idx ON turns(conversation_id, ordinal);
            CREATE INDEX IF NOT EXISTS turns_role_idx ON turns(role);

            CREATE TABLE IF NOT EXISTS envelope_edges(
                turn_id TEXT PRIMARY KEY REFERENCES turns(id) ON DELETE CASCADE,
                from_handle TEXT NOT NULL,
                to_handle TEXT NOT NULL,
                from_conversation_key TEXT NOT NULL,
                to_conversation_key TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS envelope_edges_route_idx
              ON envelope_edges(from_handle, to_handle);

            CREATE VIRTUAL TABLE IF NOT EXISTS turn_fts USING fts5(
                turn_id UNINDEXED,
                content_text,
                tokenize='unicode61 remove_diacritics 2'
            );

            CREATE TABLE IF NOT EXISTS turn_fts_rows(
                fts_rowid INTEGER PRIMARY KEY,
                turn_id TEXT NOT NULL UNIQUE REFERENCES turns(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS ingest_state(
                source_key TEXT PRIMARY KEY,
                source_revision TEXT NOT NULL,
                byte_offset INTEGER NOT NULL,
                last_line_hash TEXT,
                unknown_event_count INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS embeddings(
                turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL DEFAULT 0,
                model TEXT NOT NULL,
                model_digest TEXT NOT NULL,
                dimensions INTEGER NOT NULL,
                vector BLOB NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY(turn_id, chunk_index, model, model_digest, dimensions)
            );
            CREATE INDEX IF NOT EXISTS embeddings_model_idx
              ON embeddings(model, model_digest, dimensions);

            CREATE TABLE IF NOT EXISTS observed_schema_shapes(
                store TEXT NOT NULL,
                schema_version TEXT NOT NULL,
                shape TEXT NOT NULL,
                is_declared INTEGER NOT NULL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                PRIMARY KEY(store, schema_version, shape)
            );
            """)
        try migrateFTSRowIDsIfNeeded()
        try migrateEmbeddingChunksIfNeeded()
    }

    /// `turn_id` is an UNINDEXED FTS5 payload column. Deleting with
    /// `WHERE turn_id = ?` therefore scans the complete full-text table for
    /// every changed turn. Persist the virtual table rowid once and use its
    /// native lookup path for all subsequent updates and removals.
    private func migrateFTSRowIDsIfNeeded() throws {
        let statement = try prepare("PRAGMA user_version")
        let version = sqlite3_step(statement) == SQLITE_ROW
            ? Int(sqlite3_column_int(statement, 0))
            : 0
        sqlite3_finalize(statement)
        guard version < 2 else { return }

        try transaction {
            try execute("DELETE FROM turn_fts_rows")
            try execute("""
                INSERT INTO turn_fts_rows(fts_rowid, turn_id)
                SELECT rowid, turn_id FROM turn_fts
                """)
        }
        try execute("PRAGMA user_version=2")
    }

    private func migrateEmbeddingChunksIfNeeded() throws {
        let statement = try prepare("PRAGMA table_info(embeddings)")
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name) }
        }
        sqlite3_finalize(statement)
        guard !columns.contains("chunk_index") else { return }

        try transaction {
            try execute("DROP INDEX IF EXISTS embeddings_model_idx")
            try execute("ALTER TABLE embeddings RENAME TO embeddings_v1")
            try execute("""
                CREATE TABLE embeddings(
                    turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
                    chunk_index INTEGER NOT NULL DEFAULT 0,
                    model TEXT NOT NULL,
                    model_digest TEXT NOT NULL,
                    dimensions INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(turn_id, chunk_index, model, model_digest, dimensions)
                )
                """)
            try execute("""
                INSERT INTO embeddings(
                    turn_id, chunk_index, model, model_digest,
                    dimensions, vector, created_at
                )
                SELECT turn_id, 0, model, model_digest, dimensions, vector, created_at
                FROM embeddings_v1
                """)
            try execute("DROP TABLE embeddings_v1")
            try execute("""
                CREATE INDEX embeddings_model_idx
                ON embeddings(model, model_digest, dimensions)
                """)
        }
    }

    private func upsertConversation(
        _ descriptor: NativeConversationDescriptor,
        conversationID: String
    ) throws {
        let statement = try prepare("""
            INSERT INTO conversations(
                id, agent, lane_owner, native_session_id, source_key,
                project_key, project_alias, started_at, updated_at, source_revision
            ) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                project_key=COALESCE(excluded.project_key, conversations.project_key),
                project_alias=COALESCE(excluded.project_alias, conversations.project_alias),
                started_at=COALESCE(excluded.started_at, conversations.started_at),
                updated_at=COALESCE(excluded.updated_at, conversations.updated_at),
                source_revision=excluded.source_revision
            """)
        defer { sqlite3_finalize(statement) }
        bind(conversationID, at: 1, in: statement)
        bind(descriptor.agent.rawValue, at: 2, in: statement)
        bind(ConversationIntelligenceLane.native.rawValue, at: 3, in: statement)
        bind(descriptor.nativeSessionID, at: 4, in: statement)
        bind(sourceKey(descriptor.sourceURL), at: 5, in: statement)
        let projectKey = descriptor.projectPath.map { privateKey($0) }
        bind(projectKey, at: 6, in: statement)
        bind(projectKey.map(ConversationIntelligencePrivacy.neutralProjectAlias), at: 7, in: statement)
        bind(descriptor.startedAt?.timeIntervalSince1970, at: 8, in: statement)
        bind(descriptor.updatedAt?.timeIntervalSince1970, at: 9, in: statement)
        bind(descriptor.ingestRevision, at: 10, in: statement)
        try stepDone(statement)
    }

    private func upsertTurn(
        id: String,
        conversationID: String,
        turn: NativeConversationTurn,
        role: ConversationIntelligenceTurnRole
    ) throws -> Int {
        let normalized = ConversationIntelligenceText.normalize(turn.text)
        guard !normalized.isEmpty || !role.isDefaultSearchContent else { return 0 }
        let contentHash = ConversationIntelligenceText.sha256(normalized)
        let existingHash = try scalarText("SELECT content_hash FROM turns WHERE id = ?", binding: id)
        if existingHash == contentHash { return 0 }

        let statement = try prepare("""
            INSERT INTO turns(
                id, conversation_id, ordinal, role, native_role, content_text,
                content_hash, timestamp, source_event_id, model
            ) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                role=excluded.role,
                native_role=excluded.native_role,
                content_text=excluded.content_text,
                content_hash=excluded.content_hash,
                timestamp=COALESCE(excluded.timestamp, turns.timestamp),
                model=COALESCE(excluded.model, turns.model)
            """)
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, in: statement)
        bind(conversationID, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, Int64(turn.ordinal))
        bind(role.rawValue, at: 4, in: statement)
        bind(turn.nativeRole, at: 5, in: statement)
        bind(normalized, at: 6, in: statement)
        bind(contentHash, at: 7, in: statement)
        bind(turn.timestamp?.timeIntervalSince1970, at: 8, in: statement)
        bind(turn.sourceEventID, at: 9, in: statement)
        bind(turn.model, at: 10, in: statement)
        try stepDone(statement)

        try execute(
            "DELETE FROM turn_fts WHERE rowid = (SELECT fts_rowid FROM turn_fts_rows WHERE turn_id = ?)",
            bindings: [id]
        )
        try execute("DELETE FROM envelope_edges WHERE turn_id = ?", bindings: [id])
        if role.isDefaultSearchContent {
            try execute(
                "INSERT INTO turn_fts_rows(turn_id) VALUES(?) ON CONFLICT(turn_id) DO NOTHING",
                bindings: [id]
            )
            try execute(
                """
                INSERT INTO turn_fts(rowid, turn_id, content_text)
                SELECT fts_rowid, ?, ? FROM turn_fts_rows WHERE turn_id = ?
                """,
                bindings: [id, normalized, id]
            )
        }
        if role == .envelope, let envelope = SoyehtEnvelopeMetadata.parse(normalized) {
            let statement = try prepare("""
                INSERT INTO envelope_edges(
                    turn_id, from_handle, to_handle,
                    from_conversation_key, to_conversation_key
                ) VALUES(?,?,?,?,?)
                """)
            defer { sqlite3_finalize(statement) }
            bind(id, at: 1, in: statement)
            bind(envelope.fromHandle, at: 2, in: statement)
            bind(envelope.toHandle, at: 3, in: statement)
            bind(privateKey(envelope.fromConversationID), at: 4, in: statement)
            bind(privateKey(envelope.toConversationID), at: 5, in: statement)
            try stepDone(statement)
        }
        try execute("DELETE FROM embeddings WHERE turn_id = ?", bindings: [id])
        return 1
    }

    private func deleteTurns(conversationID: String) throws {
        try execute(
            """
            DELETE FROM turn_fts WHERE rowid IN (
                SELECT r.fts_rowid
                FROM turn_fts_rows r JOIN turns t ON t.id = r.turn_id
                WHERE t.conversation_id = ?
            )
            """,
            bindings: [conversationID]
        )
        try execute("DELETE FROM turns WHERE conversation_id = ?", bindings: [conversationID])
    }

    private func upsertCursor(
        sourceKey: String,
        revision: String,
        offset: Int64,
        lastLineHash: String?,
        unknownEvents: Int
    ) throws {
        let statement = try prepare("""
            INSERT INTO ingest_state(
                source_key, source_revision, byte_offset, last_line_hash,
                unknown_event_count, updated_at
            ) VALUES(?,?,?,?,?,?)
            ON CONFLICT(source_key) DO UPDATE SET
                source_revision=excluded.source_revision,
                byte_offset=excluded.byte_offset,
                last_line_hash=excluded.last_line_hash,
                unknown_event_count=ingest_state.unknown_event_count + excluded.unknown_event_count,
                updated_at=excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(sourceKey, at: 1, in: statement)
        bind(revision, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, offset)
        bind(lastLineHash, at: 4, in: statement)
        sqlite3_bind_int(statement, 5, Int32(unknownEvents))
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func recordSchemaObservations(
        _ observations: Set<ConversationSchemaObservation>
    ) throws {
        guard !observations.isEmpty else { return }
        let statement = try prepare("""
            INSERT INTO observed_schema_shapes(
                store, schema_version, shape, is_declared, first_seen_at, last_seen_at
            ) VALUES(?,?,?,?,?,?)
            ON CONFLICT(store, schema_version, shape) DO UPDATE SET
                is_declared=excluded.is_declared,
                last_seen_at=excluded.last_seen_at
            """)
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        for observation in observations {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(observation.store, at: 1, in: statement)
            bind(observation.schemaVersion, at: 2, in: statement)
            bind(observation.shape, at: 3, in: statement)
            sqlite3_bind_int(
                statement,
                4,
                ConversationSchemaManifest.declared.contains(observation) ? 1 : 0
            )
            sqlite3_bind_double(statement, 5, now)
            sqlite3_bind_double(statement, 6, now)
            try stepDone(statement)
        }
    }

    private func searchResult(
        statement: OpaquePointer,
        lexicalRank: Int?,
        semanticRank: Int?
    ) -> ConversationIntelligenceSearchResult {
        let rawRole = text(statement, 3) ?? "unknown"
        return ConversationIntelligenceSearchResult(
            turnID: text(statement, 0) ?? "",
            conversationID: text(statement, 1) ?? "",
            agent: text(statement, 2) ?? "unknown",
            role: ConversationIntelligenceTurnRole(rawValue: rawRole) ?? .unknown,
            projectAlias: text(statement, 4),
            timestamp: sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            snippet: text(statement, 6) ?? "",
            lexicalRank: lexicalRank,
            semanticRank: semanticRank,
            score: 0
        )
    }

    private static func conversationID(_ descriptor: NativeConversationDescriptor) -> String {
        ConversationIntelligenceText.sha256(
            "\(descriptor.agent.rawValue)\u{1f}\(descriptor.nativeSessionID)"
        )
    }

    private func sourceKey(_ url: URL) -> String {
        privateKey(url.standardizedFileURL.path)
    }

    private func privateKey(_ value: String) -> String {
        ConversationIntelligencePrivacy.privateKey(for: value, salt: identitySalt)
    }

    private static func ftsExpression(_ query: String) -> String {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    private static func decode(_ data: Data) -> [Float]? {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        var dot: Double = 0
        var leftMagnitude: Double = 0
        var rightMagnitude: Double = 0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            leftMagnitude += left * left
            rightMagnitude += right * right
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return -.infinity }
        return dot / sqrt(leftMagnitude * rightMagnitude)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let connection else { throw ConversationIntelligenceDatabaseError.sqlite("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError()
        }
        return statement
    }

    private func execute(_ sql: String, bindings: [String] = []) throws {
        if bindings.isEmpty {
            guard let connection else { throw ConversationIntelligenceDatabaseError.sqlite("database closed") }
            var errorMessage: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(errorMessage)
                throw ConversationIntelligenceDatabaseError.sqlite(message)
            }
            return
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            bind(value, at: Int32(index + 1), in: statement)
        }
        try stepDone(statement)
    }

    private func scalarText(_ sql: String, binding: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(binding, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func singleRow(_ sql: String) throws -> [Int] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return [] }
        return (0..<sqlite3_column_count(statement)).map {
            Int(sqlite3_column_int64(statement, $0))
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, conversationSQLiteTransient)
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func databaseError() -> ConversationIntelligenceDatabaseError {
        guard let connection else { return .sqlite("database closed") }
        return .sqlite(String(cString: sqlite3_errmsg(connection)))
    }
}

private extension Array where Element == Int {
    subscript(safe index: Int) -> Int? {
        indices.contains(index) ? self[index] : nil
    }
}
