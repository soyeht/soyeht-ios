import Foundation

/// One pane, one attach at a time.
///
/// Four independent code paths can decide to attach the same pane to the
/// engine: the first launch of a local shell, the restore that runs when a
/// pane view is rebound, the reattach that follows a lost transport, and a
/// restore left over from a previous launch. Each of them awaits — the login
/// PATH resolver, then HTTP — and the awaits are where two of them interleave.
/// When they do, the second attach finds the session the first one just
/// created and reports `reconnected: true`, which the launch path used to
/// treat as a fatal "stale environment" and surface as "Could not open the
/// local shell".
///
/// This gate is the mutual exclusion those four paths never had. It is a plain
/// main-actor set: every entry point already runs on the main actor, so no
/// lock is needed, only a place to record that an attach for this pane is in
/// flight across its suspension points.
@MainActor
enum EngineAttachGate {
    private static var inFlight: Set<UUID> = []

    /// Returns false when another attach for this pane is already running, in
    /// which case the caller must not start a second one.
    static func begin(_ paneID: UUID) -> Bool {
        inFlight.insert(paneID).inserted
    }

    static func end(_ paneID: UUID) {
        inFlight.remove(paneID)
    }

    static func isInFlight(_ paneID: UUID) -> Bool {
        inFlight.contains(paneID)
    }

    /// Test seam: no production caller may leave entries behind, and the tests
    /// assert that.
    static func resetForTesting() {
        inFlight.removeAll()
    }
}
