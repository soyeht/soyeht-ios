import AppKit
import SwiftUI

@MainActor
final class ConversationIntelligenceWindowController: NSWindowController {
    init(
        service: ConversationIntelligenceService,
        roots: ConversationHistoryRoots = .standard()
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Conversation Intelligence"
        window.titlebarAppearsTransparent = true
        window.center()
        window.setFrameAutosaveName("SoyehtConversationIntelligenceWindow")
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: ConversationIntelligenceRootView(service: service, roots: roots)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ConversationIntelligenceWindowController")
    }
}

@MainActor
private final class ConversationIntelligenceViewModel: ObservableObject {
    @Published var stats: ConversationIntelligenceStats?
    @Published var collaborationEdges: [ConversationCollaborationEdge] = []
    @Published var scanReport: ConversationIntelligenceScanReport?
    @Published var scanProgress: ConversationIntelligenceScanProgress?
    @Published var embeddingReport: ConversationEmbeddingReport?
    @Published var results: [ConversationIntelligenceSearchResult] = []
    @Published var query = ""
    @Published var isScanning = false
    @Published var isEmbedding = false
    @Published var isSearching = false
    @Published var isMonitoring = false
    @Published var isBackfilling = false
    @Published var errorMessage: String?

    private let service: ConversationIntelligenceService
    private let roots: ConversationHistoryRoots
    private var monitor: ConversationHistoryMonitor?
    private var scanRequestedWhileBusy = false
    private var lastProgressStatsRefresh = Date.distantPast
    private var backfillTask: Task<Void, Never>?
    private var embeddingTask: Task<Void, Never>?

    init(service: ConversationIntelligenceService, roots: ConversationHistoryRoots) {
        self.service = service
        self.roots = roots
        Task { await reloadStats() }
    }

    deinit {
        backfillTask?.cancel()
        embeddingTask?.cancel()
        monitor?.stop()
    }

    func scan(enableLiveUpdates: Bool = true) {
        guard !isScanning else {
            scanRequestedWhileBusy = true
            return
        }
        isScanning = true
        errorMessage = nil
        scanProgress = nil
        lastProgressStatsRefresh = .distantPast
        Task {
            scanReport = await service.scanRecent(
                days: 90,
                perAgentLimit: 250
            ) { [weak self] progress in
                await self?.applyScanProgress(progress)
            }
            await reloadStats()
            isScanning = false
            scanProgress = nil
            if enableLiveUpdates { startMonitoringIfNeeded() }
            if scanRequestedWhileBusy {
                scanRequestedWhileBusy = false
                scan(enableLiveUpdates: false)
            }
        }
    }

    func toggleEmbedding() {
        if isEmbedding {
            embeddingTask?.cancel()
            embeddingTask = nil
            isEmbedding = false
            return
        }
        isEmbedding = true
        errorMessage = nil
        embeddingTask = Task(priority: .utility) { [weak self] in
            var totalEmbedded = 0
            while !Task.isCancelled {
                guard let self else { return }
                let batch = await service.fillEmbeddingQueue(maxTurns: 256, batchSize: 16)
                guard !Task.isCancelled else { return }
                totalEmbedded += batch.embeddedTurns
                embeddingReport = .init(
                    embeddedTurns: totalEmbedded,
                    pendingTurns: batch.pendingTurns,
                    model: batch.model,
                    modelDigest: batch.modelDigest,
                    fallbackReason: batch.fallbackReason
                )
                await reloadStats()
                if batch.fallbackReason != nil
                    || batch.pendingTurns == 0
                    || batch.embeddedTurns == 0 {
                    isEmbedding = false
                    embeddingTask = nil
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    func toggleBackfill() {
        if isBackfilling {
            backfillTask?.cancel()
            backfillTask = nil
            isBackfilling = false
            return
        }

        isBackfilling = true
        errorMessage = nil
        startMonitoringIfNeeded()
        backfillTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.service.restartBackfillDiscovery()
            var batches = 0
            while !Task.isCancelled {
                let report = await self.service.scanBackfillBatch(perAgentLimit: 100)
                guard !Task.isCancelled else { return }
                scanReport = report
                batches += 1
                if batches.isMultiple(of: 5) || report.remainingConversations == 0 {
                    await reloadStats()
                }
                if report.remainingConversations == 0 {
                    isBackfilling = false
                    backfillTask = nil
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
        }
    }

    func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        Task {
            do {
                results = try await service.search(trimmed, limit: 30)
            } catch {
                errorMessage = "Search could not be completed."
            }
            isSearching = false
        }
    }

    func clearIndex() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear the conversation index?"
        alert.informativeText = "This removes imported turns, search vectors, collaboration edges, and derived counts. Native agent histories are not changed."
        alert.addButton(withTitle: "Clear Index")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        backfillTask?.cancel()
        backfillTask = nil
        isBackfilling = false
        embeddingTask?.cancel()
        embeddingTask = nil
        isEmbedding = false
        monitor?.stop()
        monitor = nil
        isMonitoring = false
        Task {
            do {
                try await service.clearIndex()
                results = []
                scanReport = nil
                scanProgress = nil
                embeddingReport = nil
                await reloadStats()
            } catch {
                errorMessage = "The private index could not be cleared."
            }
        }
    }

    private func reloadStats() async {
        do {
            stats = try await service.stats()
            collaborationEdges = try await service.collaborationEdges(limit: 12)
        } catch {
            errorMessage = "Conversation index is unavailable."
        }
    }

    private func applyScanProgress(_ progress: ConversationIntelligenceScanProgress) async {
        scanProgress = progress
        scanReport = progress.report

        let now = Date()
        let sourceFinished = progress.processedConversations == progress.discoveredConversations
        guard sourceFinished || now.timeIntervalSince(lastProgressStatsRefresh) >= 1 else { return }
        lastProgressStatsRefresh = now
        await reloadStats()
    }

    private func startMonitoringIfNeeded() {
        guard monitor == nil else { return }
        let monitor = ConversationHistoryMonitor(roots: roots) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scan(enableLiveUpdates: false)
            }
        }
        self.monitor = monitor
        monitor.start()
        isMonitoring = true
    }
}

private struct ConversationIntelligenceRootView: View {
    @StateObject private var model: ConversationIntelligenceViewModel

    init(service: ConversationIntelligenceService, roots: ConversationHistoryRoots) {
        _model = StateObject(
            wrappedValue: ConversationIntelligenceViewModel(service: service, roots: roots)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                privacyNotice
                controls
                if let stats = model.stats { statsView(stats) }
                if !model.collaborationEdges.isEmpty { collaborationView }
                search
                if let message = model.errorMessage {
                    Text(verbatim: message).foregroundStyle(.red)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Conversation Intelligence")
                .font(.system(size: 28, weight: .semibold))
            Text(verbatim: "Search what you and your agents have worked on — without pretending to measure attention or effort.")
                .foregroundStyle(.secondary)
        }
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Private local index").font(.headline)
                Text(verbatim: "Nothing is scanned until you click Scan. Soyeht stores the index in its private Application Support folder and contacts only a loopback Ollama endpoint with the pinned, resident qwen3-embedding:4b model. Ollama is a separate local daemon whose own behavior is outside Soyeht's security boundary. Text search works without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.scan()
            } label: {
                Label(scanButtonTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isScanning)

            Button {
                model.toggleEmbedding()
            } label: {
                Label(
                    model.isEmbedding ? "Stop semantic index" : "Update semantic index",
                    systemImage: model.isEmbedding ? "stop.circle" : "sparkles"
                )
            }
            .disabled(!model.isEmbedding && (model.stats?.searchableTurns ?? 0) == 0)

            Button {
                model.toggleBackfill()
            } label: {
                Label(
                    model.isBackfilling ? "Stop backfill" : "Backfill all history",
                    systemImage: model.isBackfilling ? "stop.circle" : "clock.arrow.circlepath"
                )
            }


            Button("Clear index…", role: .destructive) {
                model.clearIndex()
            }

            if let report = model.scanReport {
                Text(verbatim: "\(report.discoveredConversations) conversations · \(report.changedTurns) changed turns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isMonitoring {
                Label("Live while this window is open", systemImage: "wave.3.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if model.isScanning, let progress = model.scanProgress {
            VStack(alignment: .leading, spacing: 5) {
                if progress.discoveredConversations > 0 {
                    ProgressView(
                        value: Double(progress.processedConversations),
                        total: Double(progress.discoveredConversations)
                    )
                } else {
                    ProgressView()
                }
                Text(verbatim: scanProgressDescription(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(scanProgressDescription(progress))
        }
        if let report = model.scanReport, report.remainingConversations > 0 {
            Text(verbatim: "\(report.remainingConversations) older conversations remain in the background queue")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let report = model.scanReport, report.undeclaredSchemaShapes > 0 {
            Label(
                "\(report.undeclaredSchemaShapes) unsupported transcript shape(s) were excluded",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let report = model.scanReport, report.failedSources > 0 {
            Label(
                "\(report.failedSources) conversation source(s) could not be read",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let report = model.embeddingReport {
            if let fallback = report.fallbackReason {
                Label(fallback, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "\(report.embeddedTurns) turns indexed · \(report.pendingTurns) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scanButtonTitle: String {
        guard model.isScanning else { return "Scan last 90 days" }
        guard let agent = model.scanProgress?.currentAgent else { return "Scanning…" }
        return "Scanning \(agent.capitalized)…"
    }

    private func scanProgressDescription(_ progress: ConversationIntelligenceScanProgress) -> String {
        let source = "Source \(progress.sourceIndex) of \(progress.sourceCount)"
        let conversations = "\(progress.processedConversations) of \(progress.discoveredConversations) conversations"
        let turns = "\(progress.report.changedTurns) changed turns so far"
        return "\(progress.currentAgent.capitalized) · \(source) · \(conversations) · \(turns)"
    }

    @ViewBuilder
    private func statsView(_ stats: ConversationIntelligenceStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Observed activity").font(.title3.weight(.semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 135), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                metric("Conversations", value: stats.conversations)
                metric("Candidate prompts", value: stats.agents.reduce(0) { $0 + $1.humanCandidateTurns })
                metric("Agent replies", value: stats.agents.reduce(0) { $0 + $1.assistantTurns })
                metric("Agent relays", value: stats.envelopeTurns)
                metric("Excluded/control", value: stats.excludedTurns)
                metric("Semantic coverage", value: stats.embeddedTurns, detail: "of \(stats.searchableTurns)")
            }
            if !stats.agents.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        Text(verbatim: "Agent").font(.caption.weight(.semibold))
                        Text(verbatim: "Conversations").font(.caption.weight(.semibold))
                        Text(verbatim: "Candidate prompts").font(.caption.weight(.semibold))
                        Text(verbatim: "Replies").font(.caption.weight(.semibold))
                    }
                    ForEach(stats.agents) { item in
                        GridRow {
                            Text(verbatim: item.agent.capitalized)
                            Text(verbatim: "\(item.conversations)")
                            Text(verbatim: "\(item.humanCandidateTurns)")
                            Text(verbatim: "\(item.assistantTurns)")
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var collaborationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Agent collaboration").font(.title3.weight(.semibold))
            Text(verbatim: "Observed Soyeht relay envelopes. This counts messages, not human effort or attention.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text(verbatim: "From").font(.caption.weight(.semibold))
                    Text(verbatim: "To").font(.caption.weight(.semibold))
                    Text(verbatim: "Messages").font(.caption.weight(.semibold))
                }
                ForEach(model.collaborationEdges) { edge in
                    GridRow {
                        Text(verbatim: edge.fromHandle)
                        Text(verbatim: edge.toHandle)
                        Text(verbatim: "\(edge.messages)").monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }

    private func metric(_ title: String, value: Int, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(value)").font(.title2.monospacedDigit().weight(.semibold))
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            if let detail { Text(verbatim: detail).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Search conversations").font(.title3.weight(.semibold))
            HStack {
                TextField("Topic, file, decision, or project", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Search") { model.search() }
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSearching)
            }
            if model.results.isEmpty, !model.query.isEmpty, !model.isSearching {
                Text(verbatim: "No matching indexed conversations.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.results) { result in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(verbatim: result.agent.capitalized).font(.caption.weight(.semibold))
                        if let project = result.projectAlias {
                            Text(verbatim: project).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if result.semanticRank != nil { Image(systemName: "sparkles").foregroundStyle(.purple) }
                    }
                    Text(verbatim: result.snippet).textSelection(.enabled)
                    Text(verbatim: result.role == .humanCandidate ? "Candidate user prompt" : "Agent reply")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
