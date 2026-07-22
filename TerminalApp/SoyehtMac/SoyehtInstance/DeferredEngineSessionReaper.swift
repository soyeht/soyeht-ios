import Foundation
import SoyehtCore
import os

/// Defers the destructive teardown of an engine-owned (`.engineLocal`) pane
/// session after the user closes it, giving a short **undo window** during
/// which reopening the pane reconnects to the still-alive session instead of
/// resurrecting a dead one (W3 — persistent panes).
///
/// Flow:
/// - Closing a pane (`PaneViewController.endEngineSessionIfNeeded`) calls
///   `scheduleReap` instead of deleting immediately.
/// - The store's undo re-creates the pane; its reattach
///   (`restoreEnginePaneIfNeeded`) calls `cancelReap`, so the still-alive
///   session is reconnected — no history lost, because nothing died.
/// - If no undo happens within `undoWindowNanoseconds`, the reaper performs
///   the real teardown (TTY-map removal + engine `DELETE`).
/// - On app quit, pending reaps are simply abandoned (the process exits) —
///   quitting must never tear down engine sessions (persistent-panes A4), so a
///   still-pending session lingers as an engine orphan the session cap
///   reclaims, rather than being force-deleted on the way out.
///
/// Keyed by `engineConversationID` (the broker's stable id), so a new pane
/// adopting the same conversation cancels exactly the right pending reap.
@MainActor
enum DeferredEngineSessionReaper {
    /// How long a closed engine session lingers, reattachable via undo, before
    /// it is actually deleted. Single tunable source of truth (15s).
    static let undoWindowNanoseconds: UInt64 = 15 * 1_000_000_000

    private static var pending: [String: Task<Void, Never>] = [:]

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "pane.reaper")

    /// Schedule the real teardown after the undo window. Replaces (cancels)
    /// any existing pending reap for the same id.
    static func scheduleReap(engineConversationID: String) {
        pending[engineConversationID]?.cancel()
        pending[engineConversationID] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.undoWindowNanoseconds)
            if Task.isCancelled { return }
            // Claim ownership before reaping so a late cancel/flush can't
            // double-fire. On the MainActor this runs without interleaving.
            pending.removeValue(forKey: engineConversationID)
            await Self.performReap(engineConversationID: engineConversationID)
        }
    }

    /// Cancel a pending reap because a pane re-adopted this session (undo /
    /// relaunch reattach). No-op if nothing was pending.
    static func cancelReap(engineConversationID: String) {
        guard let task = pending.removeValue(forKey: engineConversationID) else { return }
        task.cancel()
        logger.info("reap cancelled (session re-adopted) pane=\(engineConversationID, privacy: .public)")
    }

    /// Number of sessions currently in the undo window (for tests/inspection).
    static var pendingCount: Int { pending.count }

    private static func performReap(engineConversationID: String) async {
        EngineSessionTTYRegistry.remove(conversationID: engineConversationID)
        guard let context = await LocalEngineContext.resolve() else {
            logger.warning("reap: no local engine context; leaving session orphaned pane=\(engineConversationID, privacy: .public)")
            return
        }
        do {
            try await SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)
            logger.info("engine session reaped pane=\(engineConversationID, privacy: .public)")
        } catch {
            logger.error("reap deleteLocalTerminal failed pane=\(engineConversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
