import AppKit
import Foundation
import SoyehtCore
import os

private let statusLogger = Logger(subsystem: "com.soyeht.mac", category: "presence")

/// Live registry of panes exposed to paired iPhones. Wraps `LivePaneRegistry`
/// (live PaneViewControllers, `LivePaneRegistry.swift:48`) + `ConversationStore`
/// on the read side and broadcasts deltas to `PairingPresenceServer` when the
/// pane set mutates.
///
/// Status derivation (H12): reads `lastOutputAt` and `exitStatus` stamps from
/// `MacOSWebSocketTerminalView`; a periodic tick recomputes transitions
/// (active→idle after 5min silence, active/idle→dead on process exit).
@MainActor
final class PaneStatusTracker {
    static let shared = PaneStatusTracker()

    /// Silence threshold for `.active` → `.idle`.
    private static let idleThreshold: TimeInterval = 5 * 60
    /// How often we re-derive status from the `lastOutputAt` stamps.
    private static let tickInterval: TimeInterval = 10

    private var idleTimer: Timer?

    // MARK: - Agent semantic state (PoC: MCP self-report + MCP liveness)

    struct AgentStateReport {
        let state: String
        let message: String?
        let seq: Int?
        let source: String
        let reportedAt: Date

        /// Harness-side reports (agent hooks/plugins, `hook:*`) outrank
        /// cooperative self-reports: an agent suspended in a permission
        /// prompt cannot self-report, so harness evidence wins.
        var authority: Int {
            source.hasPrefix("hook") ? 2 : 1
        }
    }

    /// Self-reported agent states older than this are treated as stale and no
    /// longer surfaced (the reporter may have exited silently).
    private static let agentStateStaleThreshold: TimeInterval = 10 * 60

    private var agentStateReports: [Conversation.ID: AgentStateReport] = [:]
    private var lastAcceptedReportAtBySource: [Conversation.ID: [String: Date]] = [:]
    private var lastAcceptedWorkingReportAtBySource: [Conversation.ID: [String: Date]] = [:]
    private var lastAcceptedTurnSubmissionAtBySource: [Conversation.ID: [String: Date]] = [:]
    private var lastMcpActivityAt: [Conversation.ID: Date] = [:]

    // MARK: - Launch handshake
    //
    // Agent panes get a per-launch nonce in their environment
    // (`SOYEHT_LAUNCH_NONCE`). The installed reporters echo it back on every
    // report; the first matching report is the handshake proving the agent
    // process booted and its integration is live. The initial prompt is only
    // delivered after the handshake (no more fixed sleeps / leaked prompts).

    enum HandshakeState: String {
        case notExpected = "not_expected"
        case pending
        case satisfied
        case timeout
        case delivered
    }

    private let launchOwnership = AgentLaunchOwnershipRegistry()
    private var handshakeStates: [Conversation.ID: HandshakeState] = [:]

    /// Clears runtime evidence that belongs to the previous process before a
    /// pane launches another agent in place. Without this reset, switching
    /// from a handshake-gated agent to a turn-bound one can surface the old
    /// launch as `delivered`, and the old agent's semantic state remains
    /// visible until the replacement emits its first report.
    @discardableResult
    func prepareForAgentLaunch(paneID: Conversation.ID) -> Bool {
        guard launchOwnership.prepareForLaunch(paneID: paneID) else {
            statusLogger.error("launch ownership revocation failed pane=\(paneID.uuidString, privacy: .public)")
            return false
        }
        handshakeStates[paneID] = nil
        agentStateReports[paneID] = nil
        lastAcceptedReportAtBySource[paneID] = nil
        lastAcceptedWorkingReportAtBySource[paneID] = nil
        lastAcceptedTurnSubmissionAtBySource[paneID] = nil
        lastMcpActivityAt[paneID] = nil
        return true
    }

    func quarantineAgentLaunchOwnership(paneID: Conversation.ID) {
        launchOwnership.quarantineInMemory(paneID: paneID)
        handshakeStates[paneID] = nil
        agentStateReports[paneID] = nil
        lastAcceptedReportAtBySource[paneID] = nil
        lastAcceptedWorkingReportAtBySource[paneID] = nil
        lastAcceptedTurnSubmissionAtBySource[paneID] = nil
        lastMcpActivityAt[paneID] = nil
    }

    func expectHandshake(paneID: Conversation.ID, nonce: String) {
        guard launchOwnership.validates(paneID: paneID, nonce: nonce) else {
            statusLogger.error("refusing handshake expectation without persisted ownership pane=\(paneID.uuidString, privacy: .public)")
            return
        }
        handshakeStates[paneID] = .pending
    }

    /// Every launched agent receives a possession credential, including
    /// turn-bound CLIs (Codex, etc.) that cannot emit a startup hook until
    /// after their first prompt. Handshake timing and request ownership are
    /// separate concerns.
    @discardableResult
    func registerLaunchOwnership(paneID: Conversation.ID, nonce: String) -> Bool {
        let persisted = launchOwnership.register(paneID: paneID, nonce: nonce)
        if !persisted {
            statusLogger.error("launch ownership Keychain persistence failed pane=\(paneID.uuidString, privacy: .public)")
        }
        return persisted
    }

    /// Rebuild possession expectations before any workspace pane is
    /// materialized. Persistent engine processes outlive the app and can send
    /// MCP requests while their workspace is still an unopened tab; tying
    /// this restoration to PaneViewController creation makes authentication
    /// depend on a human visiting that workspace.
    func rehydratePersistentLaunchOwnership(from conversations: [Conversation]) -> [Conversation.ID] {
        launchOwnership.rehydrate(from: conversations)
    }

    func launchOwnershipNonce(for paneID: Conversation.ID) -> String? {
        launchOwnership.nonce(for: paneID)
    }

    @discardableResult
    func restoreLaunchOwnership(paneID: Conversation.ID, nonce: String) -> Bool {
        let restored = launchOwnership.restore(paneID: paneID, nonce: nonce)
        if !restored {
            quarantineAgentLaunchOwnership(paneID: paneID)
            statusLogger.error("launch ownership rollback failed pane=\(paneID.uuidString, privacy: .public)")
        }
        return restored
    }

    func handshakeState(for paneID: Conversation.ID) -> HandshakeState {
        handshakeStates[paneID] ?? .notExpected
    }

    /// Proves that an automation mutation came from the process currently
    /// launched in this pane. Conversation IDs and handles are public routing
    /// metadata; only the per-launch nonce is a possession credential.
    func validatesLaunchOwnership(paneID: Conversation.ID, nonce: String?) -> Bool {
        launchOwnership.validates(paneID: paneID, nonce: nonce)
    }

    func markHandshakeTimeout(paneID: Conversation.ID) {
        guard handshakeStates[paneID] == .pending else { return }
        handshakeStates[paneID] = .timeout
    }

    func markHandshakeDelivered(paneID: Conversation.ID) {
        guard handshakeStates[paneID] == .satisfied else { return }
        handshakeStates[paneID] = .delivered
    }

    func markHandshakeDeliveryFailed(paneID: Conversation.ID) {
        guard handshakeStates[paneID] == .satisfied else { return }
        handshakeStates[paneID] = .timeout
    }

    /// Timestamp of the most recent accepted state report from one integration.
    /// Prompt delivery must not be acknowledged by a different agent's global
    /// hook when multiple Claude-compatible tools coexist on the machine.
    func lastReportAt(for paneID: Conversation.ID, source: String) -> Date? {
        lastAcceptedReportAtBySource[paneID]?[source]
    }

    /// Timestamp of the most recent accepted `working` report. SessionStart
    /// emits `idle`, so it must never be mistaken for proof that the initial
    /// prompt was actually submitted by the target TUI.
    func lastWorkingReportAt(for paneID: Conversation.ID, source: String) -> Date? {
        lastAcceptedWorkingReportAtBySource[paneID]?[source]
    }

    /// Only hooks that explicitly observed the provider accepting a user turn
    /// may acknowledge prompt delivery. Generic `working` tool activity is
    /// liveness evidence, not proof that the pending prompt was submitted.
    func lastTurnSubmissionAcknowledgedAt(
        for paneID: Conversation.ID,
        source: String
    ) -> Date? {
        lastAcceptedTurnSubmissionAtBySource[paneID]?[source]
    }

    /// Last known wire fingerprint of each pane, used to emit deltas only on
    /// actual change.
    private var lastSnapshotByID: [String: [String: Any]] = [:]

    /// Fase 3.1 — observation token is retained for the lifetime of the
    /// singleton (process-wide). Unique exception to the "cancel in deinit"
    /// pattern, because `PaneStatusTracker.shared` never deallocates.
    private var conversationObservationToken: ObservationToken?
    private var workspaceObservationToken: ObservationToken?
    private var windowNotificationTokens: [NSObjectProtocol] = []
    private var snapshotBroadcastTask: Task<Void, Never>?

    private init() {
        conversationObservationToken = ObservationTracker.observe(self,
            reads: { $0.observationReads() },
            onChange: { $0.recomputeAndBroadcast() }
        )
        workspaceObservationToken = ObservationTracker.observe(self,
            reads: { $0.stateObservationReads() },
            onChange: { $0.scheduleSnapshotBroadcast() }
        )
        installWindowObservers()

        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recomputeAndBroadcast() }
        }
    }

    /// Read the conversations the tracker actually derives status from.
    /// Granularity note: `store.conversation(id)` registers observation on
    /// the entire `conversations` dictionary backing, so any mutation to any
    /// conversation invalidates — same semantics as the previous
    /// NotificationCenter observer (which also listened without a filter).
    private func observationReads() {
        guard let store = AppEnvironment.conversationStore else { return }
        for id in LivePaneRegistry.shared.liveIDs {
            _ = store.conversation(id)
        }
    }

    private func stateObservationReads() {
        guard let workspaceStore = AppEnvironment.workspaceStore else { return }
        let workspaces = workspaceStore.orderedWorkspaces
        _ = workspaceStore.activeWorkspaceIDsByWindow
        _ = workspaceStore.workspaceIDsByWindowSnapshot()

        guard let conversationStore = AppEnvironment.conversationStore else { return }
        for workspace in workspaces {
            _ = workspace.name
            _ = workspace.kind
            _ = workspace.branch
            _ = workspace.layout
            _ = workspace.activePaneID
            _ = workspace.groupID
            for paneID in workspace.layout.leafIDs {
                _ = conversationStore.conversation(paneID)
            }
        }
    }

    private func installWindowObservers() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.willCloseNotification,
        ]
        windowNotificationTokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self,
                          (note.object as? NSWindow)?.windowController is SoyehtMainWindowController else {
                        return
                    }
                    self.scheduleSnapshotBroadcast()
                }
            }
        }
    }

    // MARK: - Public API

    /// Wire-ready list for `panes_snapshot`.
    func snapshotForWire() -> [[String: Any]] {
        liveEntries().map(wireDict(for:))
    }

    /// Whether the given pane is currently live.
    func hasPane(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return LivePaneRegistry.shared.pane(for: uuid) != nil
    }

    /// Looks up the live terminal view so `PaneStreamSession` can attach the
    /// output observer. Returns nil if the pane isn't a local PaneViewController
    /// (e.g. was closed in the interim).
    func terminalView(for paneID: String) -> MacOSWebSocketTerminalView? {
        guard let uuid = UUID(uuidString: paneID),
              let pvc = LivePaneRegistry.shared.pane(for: uuid) as? PaneViewController,
              pvc.isTerminalPane else {
            return nil
        }
        return pvc.terminalView
    }

    /// External callers can notify the tracker that the pane set may have
    /// changed (e.g. PaneGridController after a split/close). Internally we
    /// already listen on the `ConversationStore.changedNotification`, but
    /// callers that mutate only the layout can opt in.
    func nudgeRecompute() {
        recomputeAndBroadcast()
    }

    /// Records an agent semantic state report. Authority rules:
    /// * a lower-authority report cannot override a fresh higher-authority one;
    /// * within the same authority, reports whose `seq` is not newer than the
    ///   last accepted seq are ignored (out-of-order protection, herdr-style).
    @discardableResult
    func recordAgentStateReport(
        paneID: Conversation.ID,
        state: String,
        message: String?,
        seq: Int?,
        source: String,
        nonce: String? = nil,
        turnSubmissionAcknowledged: Bool = false
    ) -> (accepted: Bool, reason: String?) {
        if launchOwnership.validates(paneID: paneID, nonce: nonce),
           handshakeStates[paneID] == .pending {
            handshakeStates[paneID] = .satisfied
        }
        let incoming = AgentStateReport(
            state: state,
            message: message,
            seq: seq,
            source: source,
            reportedAt: Date()
        )
        if let existing = agentStateReports[paneID] {
            let existingFresh = Date().timeIntervalSince(existing.reportedAt) <= AgentAttentionNotifier.higherAuthorityWindow
            if incoming.authority < existing.authority, existingFresh {
                return (false, "lower_authority")
            }
            if incoming.authority == existing.authority,
               let seq, let existingSeq = existing.seq, seq <= existingSeq {
                return (false, "stale_seq")
            }
        }
        agentStateReports[paneID] = incoming
        lastAcceptedReportAtBySource[paneID, default: [:]][source] = incoming.reportedAt
        if state == "working" {
            lastAcceptedWorkingReportAtBySource[paneID, default: [:]][source] = incoming.reportedAt
        }
        if turnSubmissionAcknowledged {
            lastAcceptedTurnSubmissionAtBySource[paneID, default: [:]][source] = incoming.reportedAt
        }
        return (true, nil)
    }

    /// Stamps any MCP request that resolved to this pane. A fresh stamp is
    /// evidence the agent process is alive and executing.
    func recordMcpActivity(paneID: Conversation.ID) {
        lastMcpActivityAt[paneID] = Date()
    }

    func agentStateReport(for paneID: Conversation.ID) -> AgentStateReport? {
        guard let report = agentStateReports[paneID] else { return nil }
        guard Date().timeIntervalSince(report.reportedAt) <= Self.agentStateStaleThreshold else {
            agentStateReports[paneID] = nil
            return nil
        }
        return report
    }

    func lastMcpActivity(for paneID: Conversation.ID) -> Date? {
        lastMcpActivityAt[paneID]
    }

    private func forgetAutomationState(paneID: Conversation.ID) {
        agentStateReports[paneID] = nil
        lastAcceptedReportAtBySource[paneID] = nil
        lastAcceptedWorkingReportAtBySource[paneID] = nil
        lastAcceptedTurnSubmissionAtBySource[paneID] = nil
        lastMcpActivityAt[paneID] = nil
    }

    func paneDictForWire(
        id: Conversation.ID,
        conversation: Conversation,
        workspaceID: Workspace.ID? = nil,
        windowID: String? = nil,
        isFocused: Bool = false,
        orderIndex: Int? = nil
    ) -> [String: Any] {
        let terminal = terminalView(for: id.uuidString)
        let isAttachable = terminal != nil
        let status: String
        if !conversation.content.isTerminal {
            status = LivePaneRegistry.shared.pane(for: id) != nil ? "live" : "not_live"
        } else if isAttachable {
            status = computeStatus(for: (id: id, conversation: conversation))
        } else {
            switch conversation.commander {
            case .mirror:
                status = PaneWireStatus.mirror
            case .native, .engineLocal:
                status = PaneWireStatus.idle
            }
        }

        var dict: [String: Any] = [
            "id": id.uuidString,
            "title": conversation.handle,
            "agent": conversation.content.isTerminal ? conversation.agent.rawValue : conversation.content.displayKind,
            "content": conversation.content.displayKind,
            "status": status,
            "created_at": Self.iso8601(conversation.createdAt),
            "is_focused": isFocused,
            "is_live": terminal != nil || LivePaneRegistry.shared.pane(for: id) != nil,
            "is_attachable": isAttachable,
        ]
        if let workspaceID {
            dict["workspace_id"] = workspaceID.uuidString
        }
        if let windowID {
            dict["window_id"] = windowID
        }
        if let orderIndex {
            dict["order_index"] = orderIndex
        }
        if let path = conversation.content.primaryPath ?? conversation.workingDirectoryPath, !path.isEmpty {
            dict["working_directory"] = path
        }
        if let code = terminal?.exitStatus {
            dict["exit_code"] = Int(code)
        }
        return dict
    }

    // MARK: - Internals

    private func liveEntries() -> [(id: UUID, conversation: Conversation)] {
        guard let store = AppEnvironment.conversationStore else { return [] }
        let liveIDs = LivePaneRegistry.shared.liveIDs
        return liveIDs.compactMap { id -> (UUID, Conversation)? in
            guard let conv = store.conversation(id) else { return nil }
            return (id, conv)
        }
    }

    private func wireDict(for entry: (id: UUID, conversation: Conversation)) -> [String: Any] {
        paneDictForWire(id: entry.id, conversation: entry.conversation)
    }

    /// Derives a pane's wire status from live state:
    /// * `exitStatus` set on the terminal view → `.dead` (native only).
    /// * Commander `.mirror` → `.mirror` (idle/dead for remote panes is not
    ///   surfaced until we expose WS close state).
    /// * `lastOutputAt` older than `idleThreshold` → `.idle`.
    /// * Default → `.active`.
    private func computeStatus(for entry: (id: UUID, conversation: Conversation)) -> String {
        let view = terminalView(for: entry.id.uuidString)

        if let view, view.exitStatus != nil {
            return PaneWireStatus.dead
        }

        switch entry.conversation.commander {
        case .mirror:
            return PaneWireStatus.mirror
        case .native, .engineLocal:
            if let lastOutput = view?.lastOutputAt,
               Date().timeIntervalSince(lastOutput) > Self.idleThreshold {
                return PaneWireStatus.idle
            }
            return PaneWireStatus.active
        }
    }

    private func recomputeAndBroadcast() {
        let fresh = Dictionary(uniqueKeysWithValues: liveEntries().map { ($0.id.uuidString, wireDict(for: $0)) })

        let prev = lastSnapshotByID
        lastSnapshotByID = fresh

        // Diff by id.
        let added = fresh.filter { prev[$0.key] == nil }
        let removed = prev.keys.filter { fresh[$0] == nil }
        for idString in removed {
            if let uuid = UUID(uuidString: idString) {
                forgetAutomationState(paneID: uuid)
                // A missing conversation can still be inside the persistent
                // pane undo window. Ownership is revoked only by the
                // irreversible engine reaper (or an explicit switch), never
                // by this presence diff.
                if AppEnvironment.conversationStore?.conversation(uuid) == nil {
                    handshakeStates[uuid] = nil
                }
            }
        }
        let updated = fresh.compactMap { key, value -> (String, [String: Any])? in
            guard let old = prev[key] else { return nil }
            return Self.wireEqual(old, value) ? nil : (key, value)
        }

        if added.isEmpty, removed.isEmpty, updated.isEmpty { return }

        var delta: [String: Any] = [:]
        if !added.isEmpty   { delta["added"]   = Array(added.values) }
        if !updated.isEmpty { delta["updated"] = updated.map { $0.1 } }
        if !removed.isEmpty { delta["removed"] = removed }

        statusLogger.log("panes_delta added=\(added.count, privacy: .public) updated=\(updated.count, privacy: .public) removed=\(removed.count, privacy: .public)")
        PairingPresenceServer.shared.broadcastPanesDelta(delta)
        scheduleSnapshotBroadcast()
    }

    private func scheduleSnapshotBroadcast() {
        snapshotBroadcastTask?.cancel()
        snapshotBroadcastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.snapshotBroadcastTask = nil
            PairingPresenceServer.shared.broadcastPanesSnapshot()
        }
    }

    private static func wireEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard lhs.keys == rhs.keys else { return false }
        for key in lhs.keys {
            let l = lhs[key], r = rhs[key]
            if let ls = l as? String, let rs = r as? String, ls != rs { return false }
            if let li = l as? Int,    let ri = r as? Int,    li != ri { return false }
        }
        return true
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

@MainActor
enum MacPresenceSnapshotBuilder {
    static func snapshotPayload() -> [String: Any] {
        [
            "panes": PaneStatusTracker.shared.snapshotForWire(),
            "windows": windowsForWire(),
            "workspaces": workspacesForWire(windowID: nil, activeWorkspaceID: nil),
        ]
    }

    private static func windowsForWire() -> [[String: Any]] {
        NSApp.orderedWindows.compactMap { window -> [String: Any]? in
            guard let controller = window.windowController as? SoyehtMainWindowController else {
                return nil
            }
            let activeWorkspaceID = controller.activeWorkspaceID
            let title = window.title.isEmpty ? "Soyeht" : window.title
            return [
                "id": controller.windowID,
                "title": title,
                "active_workspace_id": activeWorkspaceID.uuidString,
                "is_key": window.isKeyWindow,
                "is_main": window.isMainWindow,
                "is_visible": window.isVisible,
                "is_miniaturized": window.isMiniaturized,
                "workspaces": workspacesForWire(
                    windowID: controller.windowID,
                    activeWorkspaceID: activeWorkspaceID
                ),
            ]
        }
    }

    private static func workspacesForWire(
        windowID: String?,
        activeWorkspaceID: Workspace.ID?
    ) -> [[String: Any]] {
        guard let workspaceStore = AppEnvironment.workspaceStore,
              let conversationStore = AppEnvironment.conversationStore else {
            return []
        }
        let activeByWindow = workspaceStore.activeWorkspaceIDsByWindow
        let workspaces = windowID
            .map { workspaceStore.orderedWorkspaces(in: $0) }
            ?? workspaceStore.orderedWorkspaces
        return workspaces.enumerated().map { index, workspace in
            var dict: [String: Any] = [
                "id": workspace.id.uuidString,
                "name": workspace.name,
                "kind": workspace.kind.rawValue,
                "created_at": iso8601(workspace.createdAt),
                "order_index": index,
                "is_active": activeWorkspaceID == workspace.id,
                "pane_count": workspace.layout.leafCount,
                "layout": layoutForWire(workspace.layout),
                "panes": panesForWire(
                    workspace: workspace,
                    windowID: windowID,
                    conversationStore: conversationStore
                ),
                "active_window_ids": activeByWindow.compactMap { key, value in
                    value == workspace.id ? key : nil
                }.sorted(),
            ]
            if let branch = workspace.branch, !branch.isEmpty {
                dict["branch"] = branch
            }
            if let activePaneID = workspace.activePaneID {
                dict["active_pane_id"] = activePaneID.uuidString
            }
            if let groupID = workspace.groupID {
                dict["group_id"] = groupID.uuidString
            }
            return dict
        }
    }

    private static func panesForWire(
        workspace: Workspace,
        windowID: String?,
        conversationStore: ConversationStore
    ) -> [[String: Any]] {
        workspace.layout.leafIDs.enumerated().map { index, paneID in
            if let conversation = conversationStore.conversation(paneID) {
                return PaneStatusTracker.shared.paneDictForWire(
                    id: paneID,
                    conversation: conversation,
                    workspaceID: workspace.id,
                    windowID: windowID,
                    isFocused: workspace.activePaneID == paneID,
                    orderIndex: index
                )
            }

            return placeholderPaneDictForWire(
                id: paneID,
                workspaceID: workspace.id,
                windowID: windowID,
                isFocused: workspace.activePaneID == paneID,
                orderIndex: index
            )
        }
    }

    private static func placeholderPaneDictForWire(
        id: Conversation.ID,
        workspaceID: Workspace.ID,
        windowID: String?,
        isFocused: Bool,
        orderIndex: Int
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id.uuidString,
            "title": "no session",
            "agent": PaneWireAgent.shell,
            "status": PaneWireStatus.idle,
            "workspace_id": workspaceID.uuidString,
            "is_focused": isFocused,
            "is_live": false,
            "is_attachable": false,
            "order_index": orderIndex,
        ]
        if let windowID {
            dict["window_id"] = windowID
        }
        return dict
    }

    private static func layoutForWire(_ node: PaneNode) -> [String: Any] {
        switch node {
        case .leaf(let id):
            return [
                "type": "leaf",
                "pane_id": id.uuidString,
            ]
        case .split(let axis, let ratio, let children):
            return [
                "type": "split",
                "axis": axis.rawValue,
                "ratio": Double(ratio),
                "children": children.map(layoutForWire),
            ]
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
