import Darwin
import Foundation
import SQLite3
import XCTest
@testable import SoyehtMacDomain

final class ConversationIntelligenceClassifierTests: XCTestCase {
    func testClaudeClassifierIsFailClosedAndSeparatesSoyehtEnvelope() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session-neutral.jsonl")
        let envelope = "Sent via Soyeht. From: @agent-a (conversationID: 00000000-0000-0000-0000-000000000001). To: @agent-b (conversationID: 00000000-0000-0000-0000-000000000002). Reply via Soyeht MCP message_agent. Request: delegate neutral task"
        var meta = claudeUser("meta control", uuid: "u6", promptSource: "system", origin: "human")
        meta["isMeta"] = true
        var explicitlyNotMeta = claudeUser(
            "explicit false remains human",
            uuid: "u8",
            promptSource: "typed",
            origin: "human"
        )
        explicitlyNotMeta["isMeta"] = false
        var sidechainUser = claudeUser(
            "subagent notification",
            uuid: "u10",
            promptSource: nil,
            origin: "task-notification"
        )
        sidechainUser["isMeta"] = true
        sidechainUser["isSidechain"] = true
        try writeJSONL([
            claudeUser("real human prompt", uuid: "u1", promptSource: "typed", origin: "human"),
            claudeUser(envelope, uuid: "u2", promptSource: "typed", origin: "human"),
            claudeUser("unsupported attribution shape", uuid: "u3", promptSource: "future-source", origin: "future-origin"),
            claudeUser("suggested prompt", uuid: "u4", promptSource: "suggestion_accepted", origin: "human"),
            claudeToolResult(uuid: "u5"),
            meta,
            claudeUser("task notification", uuid: "u7", promptSource: "queued", origin: "task-notification"),
            explicitlyNotMeta,
            claudeUser("sdk supplied input", uuid: "u9", promptSource: "sdk", origin: "human"),
            sidechainUser,
            claudeAssistant("assistant answer", uuid: "a1", sidechain: false),
            claudeAssistant("subagent answer", uuid: "a2", sidechain: true),
        ], to: file)

        let adapter = ClaudeConversationAdapter(rootURL: root)
        let descriptor = try XCTUnwrap(adapter.discover(updatedSince: nil, limit: nil).first)
        let result = try adapter.read(descriptor, fromByteOffset: 0)
        let roles = Dictionary(uniqueKeysWithValues: result.turns.map {
            ($0.sourceEventID ?? "", ConversationTurnClassifier.classify($0))
        })

        XCTAssertEqual(roles["u1"], .humanCandidate)
        XCTAssertEqual(roles["u2"], .envelope, "origin.kind=human must not override a Soyeht envelope")
        XCTAssertEqual(roles["u3"], .unknown, "unknown user shapes must fail closed")
        XCTAssertEqual(roles["u4"], .system, "accepted suggestions are initiated, not authored, by a human")
        XCTAssertEqual(roles["u5"], .tool)
        XCTAssertEqual(roles["u6"], .system)
        XCTAssertEqual(roles["u7"], .system)
        XCTAssertEqual(roles["u8"], .humanCandidate)
        XCTAssertEqual(roles["u9"], .unknown, "SDK input has no proof of human authorship")
        XCTAssertEqual(roles["u10"], .subagent)
        XCTAssertEqual(roles["a1"], .assistant)
        XCTAssertEqual(roles["a2"], .subagent)
        XCTAssertEqual(result.unknownEventCount, 2)
        XCTAssertEqual(
            ConversationSchemaManifest.undeclared(in: result.observedSchemaShapes),
            [.init(store: "claude", schemaVersion: "jsonl-v2", shape: "user:unknown-shape")],
            "an observed but unmanifested input shape must alarm instead of disappearing"
        )
    }

    func testCodexReadsOnlyCompleteLinesAndDoesNotDuplicateEventMessages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-neutral.jsonl")
        let meta = jsonData([
            "timestamp": "2026-08-16T10:00:00Z",
            "type": "session_meta",
            "payload": ["id": "codex-neutral", "cwd": "/neutral/project"],
        ])
        let user = jsonData([
            "timestamp": "2026-08-16T10:00:01Z",
            "type": "response_item",
            "payload": [
                "type": "message", "role": "user", "id": "user-neutral",
                "content": [["type": "input_text", "text": "build neutral feature"]],
            ],
        ])
        let environmentContext = jsonData([
            "timestamp": "2026-08-16T10:00:00Z",
            "type": "response_item",
            "payload": [
                "type": "message", "role": "user", "id": "environment-neutral",
                "content": [[
                    "type": "input_text",
                    "text": "<environment_context>\n  <cwd>/neutral/project</cwd>\n</environment_context>",
                ]],
            ],
        ])
        let userInstructions = jsonData([
            "timestamp": "2026-08-16T10:00:00Z",
            "type": "response_item",
            "payload": [
                "type": "message", "role": "user", "id": "instructions-neutral",
                "content": [[
                    "type": "input_text",
                    "text": "<user_instructions>\nNeutral harness rule.\n</user_instructions>",
                ]],
            ],
        ])
        let agentMessage = jsonData([
            "timestamp": "2026-08-16T10:00:00Z",
            "type": "response_item",
            "payload": ["type": "agent_message", "id": "agent-message-neutral"],
        ])
        let toolSearch = jsonData([
            "timestamp": "2026-08-16T10:00:00Z",
            "type": "response_item",
            "payload": ["type": "tool_search_call", "id": "tool-search-neutral"],
        ])
        let duplicateDisplay = jsonData([
            "timestamp": "2026-08-16T10:00:01Z",
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "build neutral feature"],
        ])
        let partial = String(data: jsonData([
            "timestamp": "2026-08-16T10:00:02Z",
            "type": "response_item",
            "payload": [
                "type": "message", "role": "assistant", "id": "assistant-neutral",
                "content": [["type": "output_text", "text": "neutral answer"]],
            ],
        ]), encoding: .utf8)!
        var data = Data()
        for record in [
            meta, environmentContext, userInstructions,
            agentMessage, toolSearch, user, duplicateDisplay,
        ] {
            data.append(record)
            data.append(0x0A)
        }
        data.append(Data(partial.dropLast().utf8))
        try data.write(to: file)

        let adapter = CodexConversationAdapter(rootURL: root)
        let descriptor = try XCTUnwrap(adapter.discover(updatedSince: nil, limit: nil).first)
        let first = try adapter.read(descriptor, fromByteOffset: 0)
        let firstRoles = Dictionary(uniqueKeysWithValues: first.turns.map {
            ($0.sourceEventID ?? "", ConversationTurnClassifier.classify($0))
        })
        XCTAssertEqual(firstRoles["environment-neutral"], .system)
        XCTAssertEqual(firstRoles["instructions-neutral"], .system)
        XCTAssertEqual(firstRoles["agent_message:agent-message-neutral"], .system)
        XCTAssertEqual(firstRoles["tool_search_call:tool-search-neutral"], .tool)
        XCTAssertEqual(firstRoles["user-neutral"], .humanCandidate)
        XCTAssertTrue(ConversationSchemaManifest.undeclared(in: first.observedSchemaShapes).isEmpty)

        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data([partial.utf8.last!, 0x0A]))
        try writer.close()
        let second = try adapter.read(descriptor, fromByteOffset: first.nextByteOffset)
        XCTAssertEqual(second.turns.map(\.sourceEventID), ["assistant-neutral"])
    }

    func testJSONLCursorHashAcceptsAppendButRejectsInPlaceRewrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cursor.jsonl")
        try Data("{\"value\":1}\n{\"value\":2}\n".utf8).write(to: file)
        let first = try JSONLConversationReader.read(url: file, fromByteOffset: 0)
        XCTAssertTrue(try JSONLConversationReader.cursorMatches(
            url: file,
            byteOffset: first.nextByteOffset,
            lastCompleteLineHash: first.lastCompleteLineHash
        ))

        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("{\"value\":3}\n".utf8))
        try writer.close()
        XCTAssertTrue(try JSONLConversationReader.cursorMatches(
            url: file,
            byteOffset: first.nextByteOffset,
            lastCompleteLineHash: first.lastCompleteLineHash
        ))

        try Data("{\"value\":1}\n{\"value\":9}\n{\"value\":3}\n".utf8).write(to: file)
        XCTAssertFalse(try JSONLConversationReader.cursorMatches(
            url: file,
            byteOffset: first.nextByteOffset,
            lastCompleteLineHash: first.lastCompleteLineHash
        ))
    }

    func testManifestDetectsObservedButUndeclaredStratum() {
        let newShape = ConversationSchemaObservation(
            store: "claude",
            schemaVersion: "jsonl-v3",
            shape: "user:new-shape"
        )
        XCTAssertEqual(ConversationSchemaManifest.undeclared(in: [newShape]), [newShape])
        for store in ["codex", "claude", "opencode"] {
            XCTAssertTrue(
                ConversationSchemaManifest.declared.contains(where: { $0.store == store }),
                "declared manifest stratum must not be empty: \(store)"
            )
        }
    }

    func testObservedUnknownTopLevelRecordCannotHideOutsideTheManifest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session-future.jsonl")
        try writeJSONL([
            [
                "type": "future-provider-record",
                "timestamp": "2026-08-16T10:00:00Z",
                "payload": ["kind": "neutral"],
            ],
        ], to: file)

        let adapter = ClaudeConversationAdapter(rootURL: root)
        let descriptor = try XCTUnwrap(adapter.discover(updatedSince: nil, limit: nil).first)
        let result = try adapter.read(descriptor, fromByteOffset: 0)
        let observation = ConversationSchemaObservation(
            store: "claude",
            schemaVersion: "jsonl-v2",
            shape: "record:future-provider-record"
        )
        XCTAssertEqual(result.unknownEventCount, 1)
        XCTAssertTrue(result.observedSchemaShapes.contains(observation))
        XCTAssertEqual(ConversationSchemaManifest.undeclared(in: result.observedSchemaShapes), [observation])
    }
}

final class ConversationIntelligenceDatabaseTests: XCTestCase {
    func testIngestIsIdempotentPathsAreSaltedAndRemovalCascadesEverySurface() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("intelligence.sqlite")
        let database = try ConversationIntelligenceDatabase(
            url: databaseURL,
            identitySalt: Data(repeating: 7, count: 32)
        )
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: databaseURL.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let databaseMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(databaseMode, 0o600)
        let privateSource = "/Users/user-example/Documents/project-example/session.jsonl"
        let descriptor = NativeConversationDescriptor(
            agent: .codex,
            nativeSessionID: "session-neutral",
            sourceURL: URL(fileURLWithPath: privateSource),
            projectPath: "/Users/user-example/Documents/project-example",
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            sourceRevision: "revision-1"
        )
        let observation = ConversationSchemaObservation(
            store: "codex",
            schemaVersion: "response-item-v1",
            shape: "message:user:input_text"
        )
        let result = NativeConversationReadResult(
            descriptor: descriptor,
            turns: [
                .init(
                    ordinal: 1,
                    nativeRole: "user",
                    evidence: .explicitHumanText,
                    text: "remember the neutral canary orchid",
                    timestamp: Date(timeIntervalSince1970: 101),
                    sourceEventID: "event-1",
                    model: "neutral-model",
                    metadata: [:]
                ),
            ],
            nextByteOffset: 50,
            lastCompleteLineHash: "line-hash",
            unknownEventCount: 0,
            observedSchemaShapes: [observation]
        )

        XCTAssertEqual(try database.ingest(result), 1)
        XCTAssertEqual(try database.ingest(result), 0)
        XCTAssertEqual(try database.stats().searchableTurns, 1)
        let found = try database.lexicalSearch("orchid", limit: 5)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.projectAlias?.hasPrefix("Project "), true)
        XCTAssertFalse(found.first?.projectAlias?.contains("project-example") ?? true)

        let onDisk = try databaseBytes(at: databaseURL)
        XCTAssertNil(String(data: onDisk, encoding: .utf8)?.range(of: "user-example"))
        XCTAssertNil(String(data: onDisk, encoding: .utf8)?.range(of: "project-example"))

        let envelopeText = "Sent via Soyeht. From: @agent-a (conversationID: 00000000-0000-0000-0000-000000000001). To: @agent-b (conversationID: 00000000-0000-0000-0000-000000000002). Reply via Soyeht MCP message_agent. Request: neutral delegation"
        let envelopeBatch = NativeConversationReadResult(
            descriptor: descriptor,
            turns: [
                .init(
                    ordinal: 2,
                    nativeRole: "user",
                    evidence: .soyehtEnvelope,
                    text: envelopeText,
                    timestamp: Date(timeIntervalSince1970: 102),
                    sourceEventID: "event-2",
                    model: nil,
                    metadata: [:]
                ),
            ],
            nextByteOffset: 100,
            lastCompleteLineHash: "line-hash-2",
            unknownEventCount: 0,
            observedSchemaShapes: [observation]
        )
        XCTAssertEqual(try database.ingest(envelopeBatch), 1)
        XCTAssertEqual(try database.stats().envelopeTurns, 1)
        XCTAssertEqual(
            try database.collaborationEdges(),
            [.init(fromHandle: "@agent-a", toHandle: "@agent-b", messages: 1)]
        )

        let pending = try database.pendingEmbeddings(
            model: "qwen3-embedding:4b",
            modelDigest: "digest-neutral",
            dimensions: 2,
            limit: 10
        )
        XCTAssertEqual(try database.pendingEmbeddingCount(
            model: "qwen3-embedding:4b",
            modelDigest: "digest-neutral",
            dimensions: 2
        ), 1)
        try database.storeEmbeddings(
            [.init(
                turnID: try XCTUnwrap(pending.first?.turnID),
                chunkIndex: 0,
                vector: [1, 0]
            )],
            model: "qwen3-embedding:4b",
            modelDigest: "digest-neutral",
            dimensions: 2
        )
        XCTAssertEqual(try database.stats().embeddedTurns, 1)
        XCTAssertEqual(try database.pendingEmbeddingCount(
            model: "qwen3-embedding:4b",
            modelDigest: "digest-neutral",
            dimensions: 2
        ), 0)
        let semanticScores = try database.semanticBestScores(
            queryVector: [1, 0],
            model: "qwen3-embedding:4b",
            modelDigest: "digest-neutral",
            dimensions: 2
        )
        XCTAssertEqual(
            try XCTUnwrap(semanticScores[try XCTUnwrap(pending.first?.turnID)]),
            1,
            accuracy: 0.0001
        )

        try database.removeSource(descriptor.sourceURL)
        XCTAssertEqual(try database.stats().conversations, 0)
        XCTAssertEqual(try database.stats().searchableTurns, 0)
        XCTAssertTrue(try database.lexicalSearch("orchid", limit: 5).isEmpty)
        XCTAssertTrue(try database.semanticCandidates(
            model: "qwen3-embedding:4b",
            modelDigest: "digest-neutral",
            dimensions: 2,
            limit: 10
        ).isEmpty)
        XCTAssertTrue(try database.collaborationEdges().isEmpty)
    }

    func testTruncatedSourceReplacesStaleTurnsEvenWhenFileIdentityIsStable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIntelligenceDatabase(
            url: root.appendingPathComponent("intelligence.sqlite"),
            identitySalt: Data(repeating: 8, count: 32)
        )
        let descriptor = NativeConversationDescriptor(
            agent: .codex,
            nativeSessionID: "session-truncated",
            sourceURL: root.appendingPathComponent("session.jsonl"),
            projectPath: nil,
            startedAt: nil,
            updatedAt: nil,
            sourceRevision: "stable-file-identity"
        )
        func batch(
            turns: [(Int, String, String)],
            offset: Int64
        ) -> NativeConversationReadResult {
            NativeConversationReadResult(
                descriptor: descriptor,
                turns: turns.map { ordinal, eventID, text in
                    .init(
                        ordinal: ordinal,
                        nativeRole: "user",
                        evidence: .explicitHumanText,
                        text: text,
                        timestamp: nil,
                        sourceEventID: eventID,
                        model: nil,
                        metadata: [:]
                    )
                },
                nextByteOffset: offset,
                lastCompleteLineHash: "line-\(offset)",
                unknownEventCount: 0,
                observedSchemaShapes: []
            )
        }

        try database.ingest(batch(
            turns: [(1, "old-1", "old first turn"), (2, "old-2", "stale tail canary")],
            offset: 200
        ))
        XCTAssertEqual(try database.stats().searchableTurns, 2)

        try database.ingest(batch(
            turns: [(1, "new-1", "replacement first turn")],
            offset: 80
        ))
        XCTAssertEqual(try database.stats().searchableTurns, 1)
        XCTAssertTrue(try database.lexicalSearch("stale", limit: 5).isEmpty)
        XCTAssertEqual(try database.lexicalSearch("replacement", limit: 5).count, 1)

        try database.ingest(batch(
            turns: [(2, "old-again", "second stale canary")],
            offset: 200
        ))
        try database.ingest(
            batch(turns: [(1, "rewritten", "same length rewrite")], offset: 300),
            replacingExistingSource: true
        )
        XCTAssertEqual(try database.stats().searchableTurns, 1)
        XCTAssertTrue(try database.lexicalSearch("stale", limit: 5).isEmpty)
        XCTAssertEqual(try database.lexicalSearch("rewrite", limit: 5).count, 1)
    }

    func testSecretRedactionRunsBeforeEmbeddingBoundary() {
        let raw = "Authorization: Bearer neutral-secret-token-123456 password=neutralPassword123"
        let redacted = ConversationIntelligencePrivacy.redactForEmbedding(raw)
        XCTAssertFalse(redacted.contains("neutral-secret-token-123456"))
        XCTAssertFalse(redacted.contains("neutralPassword123"))
        XCTAssertTrue(redacted.contains("REDACTED"))
    }

    func testLongTurnsAreChunkedWithoutDroppingTheirTail() {
        let head = String(repeating: "alpha ", count: 1_000)
        let tail = "tail-canary"
        let chunks = ConversationEmbeddingChunker.chunks(head + "\n\n" + tail)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= ConversationEmbeddingChunker.maxCharacters })
        XCTAssertTrue(chunks.last?.contains(tail) == true)
    }

    func testErrorsDoNotExposeRawSourcePaths() {
        let raw = "/Users/user-example/Documents/project-example/session.jsonl"
        let message = ConversationSourceAdapterError.unreadableSource(raw).localizedDescription
        XCTAssertFalse(message.contains("user-example"))
        XCTAssertFalse(message.contains("project-example"))
    }
}

final class OpenCodeConversationAdapterTests: XCTestCase {
    func testReadOnlySQLiteAdapterImportsOnlyTextPartsAndClassifiesEnvelope() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("opencode.db")
        try createOpenCodeFixture(at: dbURL)

        let adapter = OpenCodeConversationAdapter(databaseURL: dbURL)
        let descriptor = try XCTUnwrap(adapter.discover(updatedSince: nil, limit: nil).first)
        let result = try adapter.read(descriptor, fromByteOffset: 0)
        let roles = Dictionary(uniqueKeysWithValues: result.turns.map {
            ($0.sourceEventID ?? "", ConversationTurnClassifier.classify($0))
        })
        XCTAssertEqual(roles["part-user"], .humanCandidate)
        XCTAssertEqual(roles["part-assistant"], .assistant)
        XCTAssertEqual(roles["part-envelope"], .envelope)
        XCTAssertNil(roles["part-tool"])
        XCTAssertTrue(ConversationSchemaManifest.undeclared(in: result.observedSchemaShapes).isEmpty)
    }
}

final class ConversationIntelligenceE2ETests: XCTestCase {
    override func tearDown() {
        EmbeddingURLProtocol.handler = nil
        super.tearDown()
    }

    func testThreeSourceIncrementalIngestAndHybridRetrieval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        let claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        let opencodeRoot = root.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: opencodeRoot, withIntermediateDirectories: true)

        try writeJSONL([
            [
                "timestamp": "2026-08-16T10:00:00Z", "type": "session_meta",
                "payload": ["id": "codex-e2e", "cwd": "/neutral/codex-project"],
            ],
            [
                "timestamp": "2026-08-16T10:00:01Z", "type": "response_item",
                "payload": [
                    "type": "message", "role": "user", "id": "codex-user-e2e",
                    "content": [["type": "input_text", "text": "store violetcanary in botanical memory"]],
                ],
            ],
            [
                "timestamp": "2026-08-16T10:00:02Z", "type": "response_item",
                "payload": [
                    "type": "message", "role": "assistant", "id": "codex-assistant-e2e",
                    "content": [["type": "output_text", "text": "stored the requested marker"]],
                ],
            ],
        ], to: codexRoot.appendingPathComponent("rollout-e2e.jsonl"))

        try writeJSONL([
            claudeUser("prepare a neutral translation card", uuid: "claude-user-e2e", promptSource: "typed", origin: "human"),
            claudeAssistant("translation card prepared", uuid: "claude-assistant-e2e", sidechain: false),
        ], to: claudeRoot.appendingPathComponent("claude-e2e.jsonl"))
        let openCodeDB = opencodeRoot.appendingPathComponent("opencode.db")
        try createOpenCodeFixture(at: openCodeDB)

        let session = makeEmbeddingSession { input in
            let relevant = input.localizedCaseInsensitiveContains("botanical")
                || input.localizedCaseInsensitiveContains("violetcanary")
                || input.localizedCaseInsensitiveContains("plant-related")
            var vector = Array(repeating: Float(0), count: OllamaQwenEmbeddingClient.dimensions)
            vector[relevant ? 0 : 1] = 1
            return vector
        }
        let database = try ConversationIntelligenceDatabase(
            url: root.appendingPathComponent("index/intelligence.sqlite"),
            identitySalt: Data(repeating: 9, count: 32)
        )
        let service = ConversationIntelligenceService(
            database: database,
            roots: .init(
                codexSessions: codexRoot,
                claudeProjects: claudeRoot,
                openCodeDatabase: openCodeDB
            ),
            embedder: OllamaQwenEmbeddingClient(session: session)
        )

        let first = await service.scanRecent(days: 3650)
        XCTAssertEqual(first.sources.count, 3)
        XCTAssertEqual(first.discoveredConversations, 3)
        XCTAssertEqual(first.undeclaredSchemaShapes, 0)
        XCTAssertGreaterThanOrEqual(first.changedTurns, 7)

        let second = await service.scanRecent(days: 3650)
        XCTAssertEqual(second.changedTurns, 0, "durable cursors and turn keys must make rescan idempotent")

        let beforeEmbedding = try await service.stats()
        XCTAssertEqual(beforeEmbedding.conversations, 3)
        XCTAssertGreaterThanOrEqual(beforeEmbedding.excludedTurns, 1)
        let embedding = await service.fillEmbeddingQueue(maxTurns: 100, batchSize: 4)
        XCTAssertGreaterThan(embedding.embeddedTurns, 0)
        XCTAssertNil(embedding.fallbackReason)

        let semantic = try await service.search("find the plant-related memory", limit: 5)
        XCTAssertEqual(semantic.first?.agent, "codex")
        XCTAssertTrue(semantic.first?.snippet.contains("violetcanary") ?? false)
        XCTAssertNotNil(semantic.first?.semanticRank)

        // Ollama failure is not an ingestion/search outage: exact FTS remains.
        EmbeddingURLProtocol.handler = { request in
            (503, Data("{}".utf8))
        }
        let fallbackService = ConversationIntelligenceService(
            database: database,
            roots: .init(
                codexSessions: codexRoot,
                claudeProjects: claudeRoot,
                openCodeDatabase: openCodeDB
            ),
            embedder: OllamaQwenEmbeddingClient(session: session)
        )
        let lexical = try await fallbackService.search("violetcanary", limit: 5)
        XCTAssertEqual(lexical.first?.agent, "codex")
        XCTAssertNotNil(lexical.first?.lexicalRank)
    }

    func testLongAnswerTailRemainsSemanticallyRetrievable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIntelligenceDatabase(
            url: root.appendingPathComponent("index.sqlite"),
            identitySalt: Data(repeating: 4, count: 32)
        )
        let descriptor = NativeConversationDescriptor(
            agent: .codex,
            nativeSessionID: "long-session",
            sourceURL: root.appendingPathComponent("long-session.jsonl"),
            projectPath: "/neutral/long-project",
            startedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11),
            sourceRevision: "long-revision"
        )
        let longText = String(repeating: "ordinary implementation detail. ", count: 500)
            + "\n\nThe decisive concept is tailsemanticcanary in the final paragraph."
        _ = try database.ingest(.init(
            descriptor: descriptor,
            turns: [.init(
                ordinal: 1,
                nativeRole: "assistant",
                evidence: .explicitAssistantText,
                text: longText,
                timestamp: Date(timeIntervalSince1970: 11),
                sourceEventID: "long-event",
                model: "neutral-model",
                metadata: [:]
            )],
            nextByteOffset: 1,
            lastCompleteLineHash: "long-line",
            unknownEventCount: 0,
            observedSchemaShapes: []
        ))

        let session = makeEmbeddingSession { input in
            var vector = Array(repeating: Float(0), count: OllamaQwenEmbeddingClient.dimensions)
            vector[input.localizedCaseInsensitiveContains("tailsemanticcanary") ? 0 : 1] = 1
            return vector
        }
        let service = ConversationIntelligenceService(
            database: database,
            adapters: [],
            embedder: OllamaQwenEmbeddingClient(session: session)
        )
        let embedding = await service.fillEmbeddingQueue(maxTurns: 1, batchSize: 1)
        XCTAssertEqual(embedding.embeddedTurns, 1)
        let results = try await service.search("tailsemanticcanary", limit: 3)
        XCTAssertEqual(results.first?.agent, "codex")
        XCTAssertNotNil(results.first?.semanticRank)
        XCTAssertTrue(results.first?.snippet.contains("tailsemanticcanary") == true)
    }

    func testUnreadableOrMissingRootsAreReportedNotFoldedIntoZero() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIntelligenceDatabase(
            url: root.appendingPathComponent("index.sqlite"),
            identitySalt: Data(repeating: 3, count: 32)
        )
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let service = ConversationIntelligenceService(
            database: database,
            roots: .init(
                codexSessions: missing.appendingPathComponent("codex"),
                claudeProjects: missing.appendingPathComponent("claude"),
                openCodeDatabase: missing.appendingPathComponent("opencode.db")
            )
        )
        let report = await service.scanRecent(days: 90)
        XCTAssertEqual(report.sources.count, 3)
        XCTAssertTrue(report.sources.allSatisfy { $0.error != nil })
        XCTAssertTrue(report.sources.allSatisfy { !($0.error?.contains(root.path) ?? false) })
    }

    func testPerConversationReadFailuresDoNotMasqueradeAsSchemaDrift() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NativeConversationDescriptor(
            agent: .codex,
            nativeSessionID: "unreadable-neutral",
            sourceURL: root.appendingPathComponent("unreadable-neutral.jsonl"),
            projectPath: nil,
            startedAt: nil,
            updatedAt: Date(),
            sourceRevision: "unreadable-neutral-revision"
        )
        let service = ConversationIntelligenceService(
            database: try ConversationIntelligenceDatabase(
                url: root.appendingPathComponent("private-index.sqlite"),
                identitySalt: Data(repeating: 9, count: 32)
            ),
            adapters: [FailingReadConversationSourceAdapter(descriptor: descriptor)],
            embedder: OllamaQwenEmbeddingClient()
        )

        let report = await service.scanRecent(days: 90)
        let source = try XCTUnwrap(report.sources.first)
        XCTAssertEqual(source.discoveredConversations, 1)
        XCTAssertEqual(source.changedTurns, 0)
        XCTAssertEqual(source.unknownEvents, 0)
        XCTAssertEqual(source.failedSources, 1)
        XCTAssertEqual(report.failedSources, 1)
        XCTAssertNil(source.error)
    }

    func testMidWalkPermissionFailureRejectsPartialDiscovery() throws {
        guard geteuid() != 0 else {
            throw XCTSkip("permission denial cannot be simulated as root")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSONL([
            ["type": "session_meta", "payload": ["id": "visible-neutral"]],
        ], to: root.appendingPathComponent("visible.jsonl"))
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try writeJSONL([
            ["type": "session_meta", "payload": ["id": "hidden-neutral"]],
        ], to: denied.appendingPathComponent("hidden.jsonl"))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000 as Int16)],
            ofItemAtPath: denied.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700 as Int16)],
                ofItemAtPath: denied.path
            )
        }

        XCTAssertThrowsError(
            try CodexConversationAdapter(rootURL: root).discover(updatedSince: nil, limit: nil)
        )
    }

    func testAllHistoryBackfillIsBoundedAndEventuallyExhaustive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        for index in 1...3 {
            try writeJSONL([
                [
                    "timestamp": "2024-01-0\(index)T10:00:00Z",
                    "type": "session_meta",
                    "payload": ["id": "backfill-\(index)", "cwd": "/neutral/project-\(index)"],
                ],
                [
                    "timestamp": "2024-01-0\(index)T10:00:01Z",
                    "type": "response_item",
                    "payload": [
                        "type": "message", "role": "user", "id": "event-\(index)",
                        "content": [["type": "input_text", "text": "old neutral prompt \(index)"]],
                    ],
                ],
            ], to: codexRoot.appendingPathComponent("rollout-\(index).jsonl"))
        }

        let database = try ConversationIntelligenceDatabase(
            url: root.appendingPathComponent("index.sqlite"),
            identitySalt: Data(repeating: 5, count: 32)
        )
        let service = ConversationIntelligenceService(
            database: database,
            adapters: [CodexConversationAdapter(rootURL: codexRoot)],
            embedder: OllamaQwenEmbeddingClient()
        )

        let first = await service.scanBackfillBatch(perAgentLimit: 1)
        XCTAssertEqual(first.discoveredConversations, 1)
        XCTAssertEqual(first.remainingConversations, 2)
        let second = await service.scanBackfillBatch(perAgentLimit: 1)
        XCTAssertEqual(second.remainingConversations, 1)
        let third = await service.scanBackfillBatch(perAgentLimit: 1)
        XCTAssertEqual(third.remainingConversations, 0)
        let exhausted = await service.scanBackfillBatch(perAgentLimit: 1)
        XCTAssertEqual(exhausted.discoveredConversations, 0)
        XCTAssertEqual(exhausted.changedTurns, 0)
        let stats = try await service.stats()
        XCTAssertEqual(stats.conversations, 3)
    }

    func testRealMachineSourcesIncrementallyIngestWithoutPrintingContent() async throws {
        guard ProcessInfo.processInfo.environment["SOYEHT_INTELLIGENCE_REAL_E2E"] == "1" else {
            throw XCTSkip("set SOYEHT_INTELLIGENCE_REAL_E2E=1 for the local-store smoke test")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = ConversationHistoryRoots.standard()
        let liveAdapters: [any ConversationSourceAdapter] = [
            CodexConversationAdapter(rootURL: roots.codexSessions),
            ClaudeConversationAdapter(rootURL: roots.claudeProjects),
            OpenCodeConversationAdapter(databaseURL: roots.openCodeDatabase),
        ]
        let pinnedAdapters = try liveAdapters.map { adapter -> any ConversationSourceAdapter in
            let descriptors = try adapter.discover(
                updatedSince: Calendar.current.date(byAdding: .day, value: -90, to: Date()),
                limit: 1
            )
            XCTAssertEqual(descriptors.count, 1)
            return PinnedConversationSourceAdapter(base: adapter, descriptors: descriptors)
        }
        let service = ConversationIntelligenceService(
            database: try ConversationIntelligenceDatabase(
                url: root.appendingPathComponent("private-index.sqlite")
            ),
            adapters: pinnedAdapters,
            embedder: OllamaQwenEmbeddingClient()
        )

        let first = await service.scanRecent(days: 90, perAgentLimit: 1)
        XCTAssertEqual(Set(first.sources.map(\.agent)), ["codex", "claude", "opencode"])
        XCTAssertTrue(first.sources.allSatisfy { $0.error == nil })
        XCTAssertTrue(first.sources.allSatisfy { $0.discoveredConversations == 1 })
        XCTAssertEqual(
            first.undeclaredSchemaShapes,
            0,
            "every schema shape observed in the real smoke frame must have a declared stratum"
        )
        let stats = try await service.stats()
        XCTAssertEqual(stats.conversations, 3)
        XCTAssertGreaterThan(stats.searchableTurns + stats.excludedTurns, 0)

        let second = await service.scanRecent(days: 90, perAgentLimit: 1)
        let updatedStats = try await service.stats()
        XCTAssertEqual(updatedStats.conversations, stats.conversations)
        XCTAssertLessThanOrEqual(
            (updatedStats.searchableTurns + updatedStats.excludedTurns)
                - (stats.searchableTurns + stats.excludedTurns),
            second.changedTurns,
            "a concurrently active provider may append, but a rescan must not create more rows than changed native events"
        )
    }

    func testDeclaredManifestCoversBroadRecentRealCorpusFrame() throws {
        guard ProcessInfo.processInfo.environment["SOYEHT_INTELLIGENCE_REAL_E2E"] == "1" else {
            throw XCTSkip("set SOYEHT_INTELLIGENCE_REAL_E2E=1 for the real manifest coverage test")
        }
        let roots = ConversationHistoryRoots.standard()
        let adapters: [any ConversationSourceAdapter] = [
            CodexConversationAdapter(rootURL: roots.codexSessions),
            ClaudeConversationAdapter(rootURL: roots.claudeProjects),
            OpenCodeConversationAdapter(databaseURL: roots.openCodeDatabase),
        ]
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        var observed: Set<ConversationSchemaObservation> = []

        for adapter in adapters {
            let descriptors = try adapter.discover(updatedSince: cutoff, limit: 200)
            XCTAssertFalse(descriptors.isEmpty, "each real provider must contribute to the coverage frame")
            for descriptor in descriptors {
                // One bounded adapter batch per conversation is enough to
                // widen the schema frame without turning this drift gate into
                // a multi-gigabyte full-history import.
                let batch = try adapter.read(descriptor, fromByteOffset: 0)
                observed.formUnion(batch.observedSchemaShapes)
            }
        }

        XCTAssertEqual(
            ConversationSchemaManifest.undeclared(in: observed),
            [],
            "every shape observed across 200 recent conversations per provider must be declared"
        )
    }

    private func makeEmbeddingSession(
        vector: @escaping (String) -> [Float]
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbeddingURLProtocol.self]
        EmbeddingURLProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "models": [[
                        "name": OllamaQwenEmbeddingClient.pinnedModel,
                        "model": OllamaQwenEmbeddingClient.pinnedModel,
                        "size": 2_000_000_000,
                        "digest": "local-e2e-digest",
                    ]],
                ]))
            }
            let payload = try XCTUnwrap(request.capturedBody()).jsonObject()
            let inputs = payload["input"] as? [String] ?? []
            return (200, try JSONSerialization.data(withJSONObject: [
                "embeddings": inputs.map(vector),
            ]))
        }
        return URLSession(configuration: configuration)
    }
}

final class OllamaQwenEmbeddingClientTests: XCTestCase {
    override func tearDown() {
        EmbeddingURLProtocol.handler = nil
        super.tearDown()
    }

    func testCloudTaggedOrWeightlessPinnedModelIsRefused() async throws {
        let session = makeSession()
        EmbeddingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, 11434)
            let body: [String: Any] = [
                "models": [[
                    "name": OllamaQwenEmbeddingClient.pinnedModel,
                    "model": OllamaQwenEmbeddingClient.pinnedModel,
                    "size": 0,
                    "digest": "remote-route",
                ]],
            ]
            return (200, try JSONSerialization.data(withJSONObject: body))
        }
        let client = OllamaQwenEmbeddingClient(session: session)
        do {
            _ = try await client.configuration()
            XCTFail("weightless/cloud-routed model must be refused")
        } catch let error as OllamaQwenEmbeddingError {
            XCTAssertEqual(error, .cloudRoutedModelRefused(OllamaQwenEmbeddingClient.pinnedModel))
        }
    }

    func testCloudOnlyModelIsNeverSelectedThroughLoopbackDaemon() async throws {
        let session = makeSession()
        var embedRequestCount = 0
        EmbeddingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            if request.url?.path == "/api/embed" { embedRequestCount += 1 }
            return (200, try JSONSerialization.data(withJSONObject: [
                "models": [[
                    "name": "glm-5:cloud",
                    "model": "glm-5:cloud",
                    "size": 0,
                    "digest": "remote-route",
                ]],
            ]))
        }
        let client = OllamaQwenEmbeddingClient(session: session)
        do {
            _ = try await client.embedPassages(["must stay local"])
            XCTFail("a cloud-only catalog must never reach the embedding endpoint")
        } catch let error as OllamaQwenEmbeddingError {
            XCTAssertEqual(error, .pinnedModelMissing)
        }
        XCTAssertEqual(embedRequestCount, 0)
    }

    func testQueryAndPassageUseDifferentFormatsAndOnlyLoopbackRequests() async throws {
        let session = makeSession()
        let lock = NSLock()
        var embeddedInputs: [String] = []
        EmbeddingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            if request.url?.path == "/api/tags" {
                let body: [String: Any] = [
                    "models": [[
                        "name": OllamaQwenEmbeddingClient.pinnedModel,
                        "model": OllamaQwenEmbeddingClient.pinnedModel,
                        "size": 2_000_000_000,
                        "digest": "local-digest-neutral",
                    ]],
                ]
                return (200, try JSONSerialization.data(withJSONObject: body))
            }
            let payload = try XCTUnwrap(request.capturedBody()).jsonObject()
            let inputs = payload["input"] as? [String] ?? []
            lock.lock()
            embeddedInputs.append(contentsOf: inputs)
            lock.unlock()
            let vector = Array(repeating: 0.25, count: OllamaQwenEmbeddingClient.dimensions)
            return (200, try JSONSerialization.data(withJSONObject: [
                "embeddings": inputs.map { _ in vector },
            ]))
        }
        let client = OllamaQwenEmbeddingClient(session: session)
        _ = try await client.embedPassages(["plain passage"])
        _ = try await client.embedQuery("find passage")

        XCTAssertEqual(embeddedInputs.count, 2)
        XCTAssertEqual(embeddedInputs[0], "plain passage")
        XCTAssertFalse(embeddedInputs[0].hasPrefix("Instruct:"))
        XCTAssertTrue(embeddedInputs[1].hasPrefix("Instruct:"))
        XCTAssertTrue(embeddedInputs[1].contains("Query: find passage"))
    }

    func testDigestChangeDuringEmbeddingDiscardsTheBatch() async throws {
        let session = makeSession()
        var tagRequestCount = 0
        EmbeddingURLProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                tagRequestCount += 1
                return (200, try JSONSerialization.data(withJSONObject: [
                    "models": [[
                        "name": OllamaQwenEmbeddingClient.pinnedModel,
                        "model": OllamaQwenEmbeddingClient.pinnedModel,
                        "size": 2_000_000_000,
                        "digest": tagRequestCount == 1 ? "digest-before" : "digest-after",
                    ]],
                ]))
            }
            let vector = Array(repeating: 0.25, count: OllamaQwenEmbeddingClient.dimensions)
            return (200, try JSONSerialization.data(withJSONObject: ["embeddings": [vector]]))
        }

        do {
            _ = try await OllamaQwenEmbeddingClient(session: session)
                .embedPassages(["neutral passage"])
            XCTFail("a vector must not be stored under a digest that changed during the request")
        } catch let error as OllamaQwenEmbeddingError {
            XCTAssertEqual(error, .modelChangedDuringEmbedding)
        }
    }

    func testResidentQwenRanksRelevantPassageInRealDaemon() async throws {
        guard ProcessInfo.processInfo.environment["SOYEHT_INTELLIGENCE_REAL_E2E"] == "1" else {
            throw XCTSkip("set SOYEHT_INTELLIGENCE_REAL_E2E=1 for the resident-model smoke test")
        }
        let client = OllamaQwenEmbeddingClient()
        let (configuration, passages) = try await client.embedPassages([
            "A botanical memory about a violet orchid in a greenhouse.",
            "A database migration that adds an integer index to a table.",
        ])
        let (_, query) = try await client.embedQuery("Find the prior botanical flower memory")
        XCTAssertEqual(configuration.model, OllamaQwenEmbeddingClient.pinnedModel)
        XCTAssertEqual(passages.count, 2)
        XCTAssertGreaterThan(cosine(query, passages[0]), cosine(query, passages[1]))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbeddingURLProtocol.self]
        return URLSession(configuration: configuration)
    }


    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        var dot = 0.0
        var left = 0.0
        var right = 0.0
        for (lhs, rhs) in zip(lhs, rhs) {
            dot += Double(lhs * rhs)
            left += Double(lhs * lhs)
            right += Double(rhs * rhs)
        }
        guard left > 0, right > 0 else { return -.infinity }
        return dot / sqrt(left * right)
    }
}

private struct PinnedConversationSourceAdapter: ConversationSourceAdapter {
    let base: any ConversationSourceAdapter
    let descriptors: [NativeConversationDescriptor]

    var agent: ConversationIntelligenceAgent { base.agent }

    func discover(updatedSince: Date?, limit: Int?) throws -> [NativeConversationDescriptor] {
        descriptors
    }

    func read(
        _ descriptor: NativeConversationDescriptor,
        fromByteOffset: Int64
    ) throws -> NativeConversationReadResult {
        try base.read(descriptor, fromByteOffset: fromByteOffset)
    }
}

private struct FailingReadConversationSourceAdapter: ConversationSourceAdapter {
    let descriptor: NativeConversationDescriptor

    var agent: ConversationIntelligenceAgent { descriptor.agent }

    func discover(updatedSince: Date?, limit: Int?) throws -> [NativeConversationDescriptor] {
        [descriptor]
    }

    func read(
        _ descriptor: NativeConversationDescriptor,
        fromByteOffset: Int64
    ) throws -> NativeConversationReadResult {
        throw ConversationSourceAdapterError.unreadableSource("neutral")
    }
}

private final class EmbeddingURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("soyeht-intelligence-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func claudeUser(
    _ text: String,
    uuid: String,
    promptSource: String?,
    origin: String?
) -> [String: Any] {
    var object: [String: Any] = [
        "type": "user",
        "sessionId": "claude-neutral",
        "uuid": uuid,
        "timestamp": "2026-08-16T10:00:00Z",
        "cwd": "/neutral/project",
        "message": ["role": "user", "content": text],
    ]
    if let promptSource { object["promptSource"] = promptSource }
    if let origin { object["origin"] = ["kind": origin] }
    return object
}

private func claudeToolResult(uuid: String) -> [String: Any] {
    [
        "type": "user",
        "sessionId": "claude-neutral",
        "uuid": uuid,
        "timestamp": "2026-08-16T10:00:00Z",
        "cwd": "/neutral/project",
        "toolUseResult": ["status": "ok"],
        "message": [
            "role": "user",
            "content": [["type": "tool_result", "tool_use_id": "tool-neutral", "content": "tool output"]],
        ],
    ]
}

private func claudeAssistant(_ text: String, uuid: String, sidechain: Bool) -> [String: Any] {
    [
        "type": "assistant",
        "sessionId": "claude-neutral",
        "uuid": uuid,
        "timestamp": "2026-08-16T10:00:01Z",
        "cwd": "/neutral/project",
        "isSidechain": sidechain,
        "message": [
            "id": "message-\(uuid)",
            "role": "assistant",
            "model": "neutral-model",
            "content": [["type": "text", "text": text]],
        ],
    ]
}

private func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
    var data = Data()
    for object in objects {
        data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        data.append(0x0A)
    }
    try data.write(to: url)
}

private func jsonData(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func databaseBytes(at url: URL) throws -> Data {
    var data = (try? Data(contentsOf: url)) ?? Data()
    data.append((try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data())
    return data
}

private func createOpenCodeFixture(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw NSError(domain: "OpenCodeFixture", code: 1)
    }
    defer { sqlite3_close(db) }
    let envelope = "Sent via Soyeht. From: @agent-a (conversationID: 00000000-0000-0000-0000-000000000001). To: @agent-b (conversationID: 00000000-0000-0000-0000-000000000002). Reply via Soyeht MCP message_agent. Request: neutral delegation"
    let statements = [
        "CREATE TABLE session(id TEXT PRIMARY KEY, directory TEXT, time_created INTEGER, time_updated INTEGER, version TEXT)",
        "CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, data TEXT)",
        "CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)",
        "INSERT INTO session VALUES('session-neutral','/neutral/project',1786900000000,1786900005000,'1')",
        "INSERT INTO message VALUES('message-user','session-neutral','{\"role\":\"user\"}')",
        "INSERT INTO message VALUES('message-assistant','session-neutral','{\"role\":\"assistant\",\"modelID\":\"neutral-model\"}')",
        "INSERT INTO message VALUES('message-envelope','session-neutral','{\"role\":\"user\"}')",
        "INSERT INTO part VALUES('part-user','message-user','session-neutral',1786900001000,1786900001000,'{\"type\":\"text\",\"text\":\"neutral human prompt\"}')",
        "INSERT INTO part VALUES('part-assistant','message-assistant','session-neutral',1786900002000,1786900002000,'{\"type\":\"text\",\"text\":\"neutral assistant response\"}')",
        "INSERT INTO part VALUES('part-envelope','message-envelope','session-neutral',1786900003000,1786900003000,'{\"type\":\"text\",\"text\":\"\(sqlJSONEscape(envelope))\"}')",
        "INSERT INTO part VALUES('part-tool','message-assistant','session-neutral',1786900004000,1786900004000,'{\"type\":\"tool\",\"text\":\"ignored tool output\"}')",
    ]
    for statement in statements {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeFixture", code: 2)
        }
    }
}

private func sqlJSONEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "'", with: "''")
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}

private extension URLRequest {
    func capturedBody() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
