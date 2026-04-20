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

    /// Last known wire fingerprint of each pane, used to emit deltas only on
    /// actual change.
    private var lastSnapshotByID: [String: [String: Any]] = [:]

    /// Fase 3.1 — observation token is retained for the lifetime of the
    /// singleton (process-wide). Unique exception to the "cancel in deinit"
    /// pattern, because `PaneStatusTracker.shared` never deallocates.
    private var conversationObservationToken: ObservationToken?

    private init() {
        conversationObservationToken = ObservationTracker.observe(self,
            reads: { $0.observationReads() },
            onChange: { $0.recomputeAndBroadcast() }
        )

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
              let pvc = LivePaneRegistry.shared.pane(for: uuid) as? PaneViewController else {
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
        var dict: [String: Any] = [
            "id": entry.id.uuidString,
            "title": entry.conversation.handle,
            "agent": entry.conversation.agent.rawValue,
            "status": computeStatus(for: entry),
            "created_at": Self.iso8601(entry.conversation.createdAt),
        ]
        if let view = terminalView(for: entry.id.uuidString), let code = view.exitStatus {
            dict["exit_code"] = Int(code)
        }
        return dict
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
        case .native:
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
