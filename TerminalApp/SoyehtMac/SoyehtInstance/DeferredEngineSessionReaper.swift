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
    private final class ReapState {
        var committed = false
        var result = false
    }
    private struct PendingReap {
        let task: Task<Void, Never>
        let token: UInt64
        let state: ReapState
    }
    private static var pending: [String: PendingReap] = [:]
    private static var nextToken: UInt64 = 0

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "pane.reaper")

    /// Schedule the real teardown after the undo window. Replaces a still
    /// reversible timer for the same id, but never loses the handle to a
    /// DELETE that already crossed its commit boundary.
    static func scheduleReap(engineConversationID: String, paneID: Conversation.ID) {
        if let existing = pending[engineConversationID] {
            guard !existing.state.committed else {
                logger.info("reap already committed; preserving in-flight owner pane=\(engineConversationID, privacy: .public)")
                return
            }
            existing.task.cancel()
        }
        nextToken &+= 1
        let token = nextToken
        let state = ReapState()
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.undoWindowNanoseconds)
            if Task.isCancelled { return }
            // Stay registered in `pending` across `performReap` so a late
            // `cancelReap` can still cancel the in-flight reap. Clear our own
            // entry afterwards, but only if it's still ours (a replacement
            // scheduled for the same id must survive).
            let result = await Self.performReap(
                engineConversationID: engineConversationID,
                paneID: paneID,
                onCommit: { state.committed = true }
            )
            state.result = result
            if pending[engineConversationID]?.token == token {
                pending.removeValue(forKey: engineConversationID)
            }
        }
        pending[engineConversationID] = PendingReap(
            task: task,
            token: token,
            state: state
        )
    }

    /// Cancel a pending reap because a pane re-adopted this session (undo /
    /// relaunch reattach). No-op if nothing was pending. Safe to call while the
    /// reap is mid-flight: it cancels the task, which `performReap` observes via
    /// `Task.isCancelled` before committing the delete.
    static func cancelReap(engineConversationID: String) {
        guard let entry = pending[engineConversationID], !entry.state.committed else { return }
        pending.removeValue(forKey: engineConversationID)
        entry.task.cancel()
        logger.info("reap cancelled (session re-adopted) pane=\(engineConversationID, privacy: .public)")
    }

    /// Immediate teardown for a deliberate agent switch (no undo window).
    /// The pane is about to adopt a brand-new engine session, so the previous
    /// one must not linger. Cancels any pending reap for the same id first so
    /// the deferred task can't race the inline teardown.
    @discardableResult
    static func reapNow(
        engineConversationID: String,
        paneID: Conversation.ID
    ) async -> Bool {
        if let committedResult = await settlePendingReapBeforeReuse(
            engineConversationID: engineConversationID
        ) {
            return committedResult
        }
        return await Self.performReap(
            engineConversationID: engineConversationID,
            paneID: paneID,
            onCommit: {}
        )
    }

    /// Cancels a teardown only while it is still reversible. Once DELETE has
    /// been committed, a restoring pane waits for the exact task to settle;
    /// it must never race an idempotent attach against an in-flight delete.
    /// Returns the committed reap result, or nil when no delete was committed.
    static func settlePendingReapBeforeReuse(
        engineConversationID: String
    ) async -> Bool? {
        guard let entry = pending[engineConversationID] else { return nil }
        if !entry.state.committed {
            pending.removeValue(forKey: engineConversationID)
            entry.task.cancel()
            logger.info("reap cancelled before commit pane=\(engineConversationID, privacy: .public)")
            return nil
        }
        await entry.task.value
        return entry.state.result
    }

    /// Number of sessions currently in the undo window (for tests/inspection).
    static var pendingCount: Int { pending.count }

    private static func performReap(
        engineConversationID: String,
        paneID: Conversation.ID,
        onCommit: () -> Void
    ) async -> Bool {
        let previousNonce = PaneStatusTracker.shared.launchOwnershipNonce(for: paneID)
        let previousTTY = EngineSessionTTYRegistry.slaveTTYPath(
            forConversationID: engineConversationID
        )
        // Resolve the engine context first (this can suspend for several
        // seconds while the login PATH resolves). The TTY mapping is kept until
        // after the cancellation re-check below, so a reattach during this
        // window can still resolve it.
        guard let context = await LocalEngineContext.resolve() else {
            logger.warning("reap: no local engine context; leaving session orphaned pane=\(engineConversationID, privacy: .public)")
            return false
        }
        // A ⌘Z that arrived during the sleep or the resolve above cancelled this
        // task — bail before the irreversible teardown so the re-adopted session
        // survives (the reattach reconnects to it).
        if Task.isCancelled { return false }
        // From here onward cancellation cannot make the delete un-happen.
        // Undo/reattach must await this operation rather than racing it.
        onCommit()
        // Revoke the old process before the irreversible DELETE. A switch can
        // then abort with the original process intact if durable revocation is
        // unavailable; a close leaves an orphan rather than a stale bearer.
        guard PaneStatusTracker.shared.prepareForAgentLaunch(paneID: paneID) else {
            logger.error("reap: ownership tombstone failed; delete aborted pane=\(paneID.uuidString, privacy: .public)")
            return false
        }
        EngineSessionTTYRegistry.remove(conversationID: engineConversationID)
        do {
            try await SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)
            logger.info("engine session reaped pane=\(engineConversationID, privacy: .public)")
            return true
        } catch {
            if let previousTTY {
                EngineSessionTTYRegistry.record(
                    conversationID: engineConversationID,
                    slaveTTYPath: previousTTY
                )
            }
            if let previousNonce,
               !PaneStatusTracker.shared.restoreLaunchOwnership(
                   paneID: paneID,
                   nonce: previousNonce
               ) {
                logger.fault("reap rollback failed; live session quarantined pane=\(paneID.uuidString, privacy: .public)")
            }
            logger.error("reap deleteLocalTerminal failed pane=\(engineConversationID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
