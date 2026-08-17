import Foundation

struct ConversationHistoryRoots: Sendable {
    let codexSessions: URL
    let claudeProjects: URL
    let openCodeDatabase: URL

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(
            codexSessions: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            claudeProjects: home.appendingPathComponent(".claude/projects", isDirectory: true),
            openCodeDatabase: home.appendingPathComponent(
                ".local/share/opencode/opencode.db",
                isDirectory: false
            )
        )
    }
}

struct ConversationIntelligenceScanReport: Equatable, Sendable {
    struct Source: Equatable, Sendable, Identifiable {
        let agent: String
        let discoveredConversations: Int
        let changedTurns: Int
        let unknownEvents: Int
        let failedSources: Int
        let remainingConversations: Int
        let error: String?

        var id: String { agent }
    }

    let startedAt: Date
    let finishedAt: Date
    let sources: [Source]
    let undeclaredSchemaShapes: Int

    var discoveredConversations: Int {
        sources.reduce(0) { $0 + $1.discoveredConversations }
    }

    var changedTurns: Int {
        sources.reduce(0) { $0 + $1.changedTurns }
    }

    var remainingConversations: Int {
        sources.reduce(0) { $0 + $1.remainingConversations }
    }

    var failedSources: Int {
        sources.reduce(0) { $0 + $1.failedSources }
    }
}

struct ConversationIntelligenceScanProgress: Equatable, Sendable {
    let report: ConversationIntelligenceScanReport
    let currentAgent: String
    let sourceIndex: Int
    let sourceCount: Int
    let processedConversations: Int
    let discoveredConversations: Int
}

struct ConversationEmbeddingReport: Equatable, Sendable {
    let embeddedTurns: Int
    let pendingTurns: Int
    let model: String?
    let modelDigest: String?
    let fallbackReason: String?
}

struct ConversationHybridSearchConfiguration: Equatable, Sendable {
    var lexicalWeight: Double = 1.0
    var semanticWeight: Double = 1.0
    var reciprocalRankConstant: Double = 60
}

actor ConversationIntelligenceService {
    private struct IngestCounts: Sendable {
        var changed = 0
        var unknown = 0
        var failed = 0

        static func + (lhs: Self, rhs: Self) -> Self {
            .init(
                changed: lhs.changed + rhs.changed,
                unknown: lhs.unknown + rhs.unknown,
                failed: lhs.failed + rhs.failed
            )
        }

        static func += (lhs: inout Self, rhs: Self) {
            lhs = lhs + rhs
        }
    }

    private struct BackfillQueue {
        let descriptors: [NativeConversationDescriptor]
        var nextIndex: Int

        var remaining: Int { max(0, descriptors.count - nextIndex) }
    }

    private let database: ConversationIntelligenceDatabase
    private let adapters: [any ConversationSourceAdapter]
    private let embedder: OllamaQwenEmbeddingClient
    private var backfillQueues: [ConversationIntelligenceAgent: BackfillQueue]?
    private var backfillErrors: [ConversationIntelligenceAgent: String] = [:]

    init(
        database: ConversationIntelligenceDatabase,
        roots: ConversationHistoryRoots = .standard(),
        embedder: OllamaQwenEmbeddingClient = OllamaQwenEmbeddingClient()
    ) {
        self.database = database
        self.adapters = [
            CodexConversationAdapter(rootURL: roots.codexSessions),
            ClaudeConversationAdapter(rootURL: roots.claudeProjects),
            OpenCodeConversationAdapter(databaseURL: roots.openCodeDatabase),
        ]
        self.embedder = embedder
    }

    init(
        database: ConversationIntelligenceDatabase,
        adapters: [any ConversationSourceAdapter],
        embedder: OllamaQwenEmbeddingClient
    ) {
        self.database = database
        self.adapters = adapters
        self.embedder = embedder
    }

    /// Scans recent sessions first. Calling the method again resumes each
    /// source from its durable cursor; unchanged turns do not create rows.
    func scanRecent(
        days: Int = 90,
        perAgentLimit: Int? = nil,
        onProgress: (@Sendable (ConversationIntelligenceScanProgress) async -> Void)? = nil
    ) async -> ConversationIntelligenceScanReport {
        let startedAt = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, days), to: startedAt)
        var sourceReports: [ConversationIntelligenceScanReport.Source] = []

        for (sourceOffset, adapter) in adapters.enumerated() {
            do {
                let descriptors = try adapter.discover(updatedSince: cutoff, limit: perAgentLimit)
                var counts = IngestCounts()
                await emitRecentScanProgress(
                    startedAt: startedAt,
                    completedSources: sourceReports,
                    adapter: adapter,
                    sourceIndex: sourceOffset + 1,
                    processedConversations: 0,
                    discoveredConversations: descriptors.count,
                    counts: counts,
                    onProgress: onProgress
                )

                for (descriptorOffset, descriptor) in descriptors.enumerated() {
                    let countsBeforeDescriptor = counts
                    let completedSources = sourceReports
                    let descriptorCounts = await ingestDescriptor(
                        descriptor,
                        with: adapter
                    ) { [self] partialCounts in
                        await emitRecentScanProgress(
                            startedAt: startedAt,
                            completedSources: completedSources,
                            adapter: adapter,
                            sourceIndex: sourceOffset + 1,
                            processedConversations: descriptorOffset,
                            discoveredConversations: descriptors.count,
                            counts: countsBeforeDescriptor + partialCounts,
                            onProgress: onProgress
                        )
                    }
                    counts += descriptorCounts
                    await emitRecentScanProgress(
                        startedAt: startedAt,
                        completedSources: sourceReports,
                        adapter: adapter,
                        sourceIndex: sourceOffset + 1,
                        processedConversations: descriptorOffset + 1,
                        discoveredConversations: descriptors.count,
                        counts: counts,
                        onProgress: onProgress
                    )
                }

                sourceReports.append(sourceReport(
                    adapter: adapter,
                    discoveredConversations: descriptors.count,
                    counts: counts
                ))
            } catch {
                sourceReports.append(.init(
                    agent: adapter.agent.rawValue,
                    discoveredConversations: 0,
                    changedTurns: 0,
                    unknownEvents: 0,
                    failedSources: 0,
                    remainingConversations: 0,
                    error: Self.safeSourceError(error, agent: adapter.agent)
                ))
                await emitRecentScanProgress(
                    startedAt: startedAt,
                    completedSources: Array(sourceReports.dropLast()),
                    adapter: adapter,
                    sourceIndex: sourceOffset + 1,
                    processedConversations: 0,
                    discoveredConversations: 0,
                    counts: .init(),
                    error: sourceReports.last?.error,
                    onProgress: onProgress
                )
            }
        }

        let driftCount = (try? database.undeclaredSchemaObservations().count) ?? 0
        return ConversationIntelligenceScanReport(
            startedAt: startedAt,
            finishedAt: Date(),
            sources: sourceReports,
            undeclaredSchemaShapes: driftCount
        )
    }

    /// Imports older history in bounded batches. The full discovery list is
    /// built once and kept only in memory so tens of thousands of Codex files
    /// are not rediscovered for every batch. Already-cursored sources are
    /// skipped; recent/live ingestion remains idempotent with this backfill.
    func scanBackfillBatch(perAgentLimit: Int = 100) async -> ConversationIntelligenceScanReport {
        let startedAt = Date()
        if backfillQueues == nil {
            var queues: [ConversationIntelligenceAgent: BackfillQueue] = [:]
            for adapter in adapters {
                do {
                    let all = try adapter.discover(updatedSince: nil, limit: nil)
                    let missing = try all.filter { descriptor in
                        guard let cursor = try database.cursor(for: descriptor.sourceURL) else {
                            return true
                        }
                        return cursor.sourceRevision != descriptor.ingestRevision
                    }
                    queues[adapter.agent] = BackfillQueue(descriptors: missing, nextIndex: 0)
                } catch {
                    backfillErrors[adapter.agent] = Self.safeSourceError(error, agent: adapter.agent)
                    queues[adapter.agent] = BackfillQueue(descriptors: [], nextIndex: 0)
                }
            }
            backfillQueues = queues
        }

        var reports: [ConversationIntelligenceScanReport.Source] = []
        let batchLimit = max(1, perAgentLimit)
        for adapter in adapters {
            guard var queue = backfillQueues?[adapter.agent] else { continue }
            let end = min(queue.descriptors.count, queue.nextIndex + batchLimit)
            let selected = queue.nextIndex < end
                ? Array(queue.descriptors[queue.nextIndex..<end])
                : []
            queue.nextIndex = end
            backfillQueues?[adapter.agent] = queue

            let counts = await ingestDescriptors(selected, with: adapter)
            reports.append(.init(
                agent: adapter.agent.rawValue,
                discoveredConversations: selected.count,
                changedTurns: counts.changed,
                unknownEvents: counts.unknown,
                failedSources: counts.failed,
                remainingConversations: queue.remaining,
                error: backfillErrors[adapter.agent]
            ))
        }

        let driftCount = (try? database.undeclaredSchemaObservations().count) ?? 0
        return .init(
            startedAt: startedAt,
            finishedAt: Date(),
            sources: reports,
            undeclaredSchemaShapes: driftCount
        )
    }

    func stats() throws -> ConversationIntelligenceStats {
        try database.stats()
    }

    func collaborationEdges(limit: Int = 20) throws -> [ConversationCollaborationEdge] {
        try database.collaborationEdges(limit: limit)
    }

    func clearIndex() throws {
        try database.clearAll()
        backfillQueues = nil
        backfillErrors = [:]
    }

    func restartBackfillDiscovery() {
        backfillQueues = nil
        backfillErrors = [:]
    }

    /// Embedding is a separate, restartable pipeline. Ingestion and lexical
    /// search remain healthy while Ollama is unavailable.
    func fillEmbeddingQueue(maxTurns: Int = 128, batchSize: Int = 16) async -> ConversationEmbeddingReport {
        do {
            let configuration = try await embedder.configuration()
            var embedded = 0
            while embedded < max(1, maxTurns) {
                let batch = try database.pendingEmbeddings(
                    model: configuration.model,
                    modelDigest: configuration.digest,
                    dimensions: configuration.dimensions,
                    limit: min(max(1, batchSize), maxTurns - embedded)
                )
                guard !batch.isEmpty else { break }
                let chunks = batch.flatMap { turn in
                    ConversationEmbeddingChunker.chunks(turn.text).enumerated().map {
                        (turnID: turn.turnID, chunkIndex: $0.offset, text: $0.element)
                    }
                }
                var vectors: [[Float]] = []
                var embeddedConfiguration: OllamaQwenEmbeddingClient.Configuration?
                for start in stride(from: 0, to: chunks.count, by: 64) {
                    let end = min(chunks.count, start + 64)
                    let (partConfiguration, part) = try await embedder.embedPassages(
                        chunks[start..<end].map(\.text)
                    )
                    if let embeddedConfiguration,
                       embeddedConfiguration != partConfiguration {
                        throw OllamaQwenEmbeddingError.modelChangedDuringEmbedding
                    }
                    embeddedConfiguration = partConfiguration
                    vectors.append(contentsOf: part)
                }
                guard let embeddedConfiguration,
                      embeddedConfiguration == configuration else {
                    throw OllamaQwenEmbeddingError.modelChangedDuringEmbedding
                }
                let stored = zip(chunks, vectors).map {
                    ConversationIntelligenceDatabase.StoredEmbedding(
                        turnID: $0.0.turnID,
                        chunkIndex: $0.0.chunkIndex,
                        vector: $0.1
                    )
                }
                try database.storeEmbeddings(
                    stored,
                    model: embeddedConfiguration.model,
                    modelDigest: embeddedConfiguration.digest,
                    dimensions: embeddedConfiguration.dimensions
                )
                embedded += batch.count
            }
            let pending = try database.pendingEmbeddingCount(
                model: configuration.model,
                modelDigest: configuration.digest,
                dimensions: configuration.dimensions
            )
            return .init(
                embeddedTurns: embedded,
                pendingTurns: pending,
                model: configuration.model,
                modelDigest: configuration.digest,
                fallbackReason: nil
            )
        } catch {
            let pending = (try? database.stats().pendingEmbeddingTurns) ?? 0
            return .init(
                embeddedTurns: 0,
                pendingTurns: pending,
                model: nil,
                modelDigest: nil,
                fallbackReason: Self.safeEmbeddingError(error)
            )
        }
    }

    func search(
        _ query: String,
        limit: Int = 20,
        configuration searchConfiguration: ConversationHybridSearchConfiguration = .init()
    ) async throws -> [ConversationIntelligenceSearchResult] {
        let lexical = try database.lexicalSearch(query, limit: max(limit * 3, 30))
        var semanticIDs: [String] = []

        do {
            let (configuration, queryVector) = try await embedder.embedQuery(query)
            let bestSimilarityByTurn = try database.semanticBestScores(
                queryVector: queryVector,
                model: configuration.model,
                modelDigest: configuration.digest,
                dimensions: configuration.dimensions
            )
            semanticIDs = bestSimilarityByTurn
                .map { ($0.key, $0.value) }
                .sorted { lhs, rhs in
                    if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
                    return lhs.1 > rhs.1
                }
                .prefix(max(limit * 3, 30))
                .map(\.0)
        } catch {
            // FTS-only is a complete, intentional operating mode.
        }

        let semanticBase = try database.searchResults(turnIDs: semanticIDs)
        var all = Dictionary(uniqueKeysWithValues: lexical.map { ($0.turnID, $0) })
        for (id, result) in semanticBase { all[id] = all[id] ?? result }

        var scores: [String: Double] = [:]
        var lexicalRanks: [String: Int] = [:]
        var semanticRanks: [String: Int] = [:]
        for (offset, result) in lexical.enumerated() {
            let rank = offset + 1
            lexicalRanks[result.turnID] = rank
            scores[result.turnID, default: 0] += searchConfiguration.lexicalWeight
                / (searchConfiguration.reciprocalRankConstant + Double(rank))
        }
        for (offset, id) in semanticIDs.enumerated() {
            let rank = offset + 1
            semanticRanks[id] = rank
            scores[id, default: 0] += searchConfiguration.semanticWeight
                / (searchConfiguration.reciprocalRankConstant + Double(rank))
        }

        return all.values.map { base in
            ConversationIntelligenceSearchResult(
                turnID: base.turnID,
                conversationID: base.conversationID,
                agent: base.agent,
                role: base.role,
                projectAlias: base.projectAlias,
                timestamp: base.timestamp,
                snippet: base.snippet,
                lexicalRank: lexicalRanks[base.turnID],
                semanticRank: semanticRanks[base.turnID],
                score: scores[base.turnID, default: 0]
            )
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.turnID < rhs.turnID }
            return lhs.score > rhs.score
        }.prefix(max(1, limit)).map { $0 }
    }

    private func emitRecentScanProgress(
        startedAt: Date,
        completedSources: [ConversationIntelligenceScanReport.Source],
        adapter: any ConversationSourceAdapter,
        sourceIndex: Int,
        processedConversations: Int,
        discoveredConversations: Int,
        counts: IngestCounts,
        error: String? = nil,
        onProgress: (@Sendable (ConversationIntelligenceScanProgress) async -> Void)?
    ) async {
        guard let onProgress else { return }
        let currentSource = ConversationIntelligenceScanReport.Source(
            agent: adapter.agent.rawValue,
            discoveredConversations: processedConversations,
            changedTurns: counts.changed,
            unknownEvents: counts.unknown,
            failedSources: counts.failed,
            remainingConversations: 0,
            error: error
        )
        let report = ConversationIntelligenceScanReport(
            startedAt: startedAt,
            finishedAt: Date(),
            sources: completedSources + [currentSource],
            undeclaredSchemaShapes: 0
        )
        await onProgress(.init(
            report: report,
            currentAgent: adapter.agent.rawValue,
            sourceIndex: sourceIndex,
            sourceCount: adapters.count,
            processedConversations: processedConversations,
            discoveredConversations: discoveredConversations
        ))
    }

    private func sourceReport(
        adapter: any ConversationSourceAdapter,
        discoveredConversations: Int,
        counts: IngestCounts
    ) -> ConversationIntelligenceScanReport.Source {
        .init(
            agent: adapter.agent.rawValue,
            discoveredConversations: discoveredConversations,
            changedTurns: counts.changed,
            unknownEvents: counts.unknown,
            failedSources: counts.failed,
            remainingConversations: 0,
            error: nil
        )
    }

    private func ingestDescriptors(
        _ descriptors: [NativeConversationDescriptor],
        with adapter: any ConversationSourceAdapter
    ) async -> IngestCounts {
        var counts = IngestCounts()
        for descriptor in descriptors {
            counts += await ingestDescriptor(descriptor, with: adapter)
        }
        return counts
    }

    private func ingestDescriptor(
        _ descriptor: NativeConversationDescriptor,
        with adapter: any ConversationSourceAdapter,
        onBatch: (@Sendable (IngestCounts) async -> Void)? = nil
    ) async -> IngestCounts {
        var counts = IngestCounts()
        do {
            let cursor = try database.cursor(for: descriptor.sourceURL)
            let hasMatchingRevision = cursor?.sourceRevision == descriptor.ingestRevision
            let hasValidJSONLCursor: Bool
            if let cursor, [.codex, .claude].contains(descriptor.agent) {
                hasValidJSONLCursor = try JSONLConversationReader.cursorMatches(
                    url: descriptor.sourceURL,
                    byteOffset: cursor.byteOffset,
                    lastCompleteLineHash: cursor.lastCompleteLineHash
                )
            } else {
                hasValidJSONLCursor = true
            }
            var offset = hasMatchingRevision && hasValidJSONLCursor
                ? cursor?.byteOffset ?? 0
                : 0
            var replaceOnNextBatch = cursor != nil
                && (!hasMatchingRevision || !hasValidJSONLCursor)
            // JSONL is parsed in bounded byte batches so a very long
            // session cannot make the app mirror the whole file in RAM.
            // SQLite adapters naturally stop when their high-water mark
            // no longer advances.
            for _ in 0..<256 {
                let batch = try adapter.read(descriptor, fromByteOffset: offset)
                guard batch.nextByteOffset > offset else { break }
                counts.changed += try database.ingest(
                    batch,
                    replacingExistingSource: replaceOnNextBatch
                )
                replaceOnNextBatch = false
                counts.unknown += batch.unknownEventCount
                offset = batch.nextByteOffset
                await onBatch?(counts)
            }
        } catch {
            counts.failed += 1
            await onBatch?(counts)
        }
        return counts
    }

    private static func safeSourceError(
        _ error: Error,
        agent: ConversationIntelligenceAgent
    ) -> String {
        switch error {
        case is ConversationSourceAdapterError:
            return "\(agent.rawValue) history is unavailable or uses an unsupported schema"
        default:
            return "\(agent.rawValue) history scan failed"
        }
    }

    private static func safeEmbeddingError(_ error: Error) -> String {
        (error as? OllamaQwenEmbeddingError)?.errorDescription
            ?? "Local semantic indexing is unavailable; text search remains available."
    }
}
