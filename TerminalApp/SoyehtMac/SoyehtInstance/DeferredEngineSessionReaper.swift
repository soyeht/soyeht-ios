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
///
/// **Cancellation safety:** the scheduled `Task` stays registered in `pending`
/// for the *entire* reap — including while `performReap` is suspended on engine
/// I/O — so a late `cancelReap` (⌘Z arriving after the 15s sleep but before the
/// DELETE is sent) can still find and cancel it. `performReap` re-checks
/// `Task.isCancelled` after resolving the engine context and only then commits
/// the irreversible teardown, so a re-adopted session is never deleted out from
/// under the pane that just reconnected to it.
@MainActor
enum DeferredEngineSessionReaper {
    /// How long a closed engine session lingers, reattachable via undo, before
    /// it is actually deleted. Single tunable source of truth (15s).
    static let undoWindowNanoseconds: UInt64 = 15 * 1_000_000_000

    /// The scheduled task plus a monotonic token identifying *this* schedule,
    /// so a task that finishes reaping only clears its own entry and never a
    /// replacement scheduled for the same id while it was in flight.
    private static var pending: [String: (task: Task<Void, Never>, token: UInt64)] = [:]
    private static var nextToken: UInt64 = 0

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "pane.reaper")

    /// Schedule the real teardown after the undo window. Replaces (cancels)
    /// any existing pending reap for the same id.
    static func scheduleReap(engineConversationID: String) {
        pending[engineConversationID]?.task.cancel()
        nextToken &+= 1
        let token = nextToken
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.undoWindowNanoseconds)
            if Task.isCancelled { return }
            // Stay registered in `pending` across `performReap` so a late
            // `cancelReap` can still cancel the in-flight reap. Clear our own
            // entry afterwards, but only if it's still ours (a replacement
            // scheduled for the same id must survive).
            await Self.performReap(engineConversationID: engineConversationID)
            if pending[engineConversationID]?.token == token {
                pending.removeValue(forKey: engineConversationID)
            }
        }
        pending[engineConversationID] = (task: task, token: token)
    }

    /// Cancel a pending reap because a pane re-adopted this session (undo /
    /// relaunch reattach). No-op if nothing was pending. Safe to call while the
    /// reap is mid-flight: it cancels the task, which `performReap` observes via
    /// `Task.isCancelled` before committing the delete.
    static func cancelReap(engineConversationID: String) {
        guard let entry = pending.removeValue(forKey: engineConversationID) else { return }
        entry.task.cancel()
        logger.info("reap cancelled (session re-adopted) pane=\(engineConversationID, privacy: .public)")
    }

    /// Number of sessions currently in the undo window (for tests/inspection).
    static var pendingCount: Int { pending.count }

    private static func performReap(engineConversationID: String) async {
        // Resolve the engine context first (this can suspend for several
        // seconds while the login PATH resolves). The TTY mapping is kept until
        // after the cancellation re-check below, so a reattach during this
        // window can still resolve it.
        guard let context = await LocalEngineContext.resolve() else {
            logger.warning("reap: no local engine context; leaving session orphaned pane=\(engineConversationID, privacy: .public)")
            return
        }
        // A ⌘Z that arrived during the sleep or the resolve above cancelled this
        // task — bail before the irreversible teardown so the re-adopted session
        // survives (the reattach reconnects to it).
        if Task.isCancelled { return }
        EngineSessionTTYRegistry.remove(conversationID: engineConversationID)
        do {
            try await SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)
            logger.info("engine session reaped pane=\(engineConversationID, privacy: .public)")
        } catch {
            logger.error("reap deleteLocalTerminal failed pane=\(engineConversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
