import AppKit

/// Holds weak references to `PaneViewController` instances keyed by
/// `Conversation.ID`. The sidebar window reaches into the main window's live
/// panes through this registry — never through direct NSWindow refs, which
/// keeps multi-window coordination tractable.
///
/// All access is on the main actor; callers off-main must hop first.
@MainActor
final class LivePaneRegistry {

    static let shared = LivePaneRegistry()

    private var entries: [Conversation.ID: WeakBox<NSViewController>] = [:]

    func register(_ id: Conversation.ID, pane: NSViewController) {
        entries[id] = WeakBox(pane)
    }

    func unregister(_ id: Conversation.ID) {
        entries.removeValue(forKey: id)
    }

    /// Returns nil if the pane was deallocated (and cleans up the stale key).
    func pane(for id: Conversation.ID) -> NSViewController? {
        guard let box = entries[id] else { return nil }
        if let vc = box.value { return vc }
        entries.removeValue(forKey: id)
        return nil
    }

    /// All currently-live conversation IDs. Drops stale entries.
    var liveIDs: [Conversation.ID] {
        let stale = entries.compactMap { $0.value.value == nil ? $0.key : nil }
        for id in stale { entries.removeValue(forKey: id) }
        return Array(entries.keys)
    }
}

/// Minimal weak box. `NSHashTable.weakObjects()` would also work but is
/// awkward for keyed lookup.
private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
