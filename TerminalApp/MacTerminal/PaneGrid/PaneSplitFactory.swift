import AppKit
import os

/// NSSplitView subclass that draws an 8pt black divider, matching the design's
/// paneGrid gap (`Eve85.gap = 8`, fill `#000000`).
@MainActor
final class GapSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 8 }
    override var dividerColor: NSColor { .black }
    override func drawDivider(in rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }
}

/// Vanilla NSSplitViewController. We used to customize its splitView but that
/// broke `addSplitViewItem` routing — customizations now live in the delegate
/// path or post-factory layout tweaks.
@MainActor
final class GapSplitViewController: NSSplitViewController {}

/// Builds an NSSplitViewController tree from a `PaneNode` *while preserving
/// identity* of existing `PaneViewController` instances. This is the core
/// guarantee that keeps live WebSockets alive across splits.
///
/// Identity key: `Conversation.ID`. Every `.leaf(id)` in the new tree either
/// maps to the same `PaneViewController` instance from the prior reconcile
/// (found in `cache`) or — if brand new — a freshly constructed one.
///
/// Split containers are created fresh each reconcile, but their child view
/// controllers are reused, so AppKit sees existing `NSView` subtrees moved
/// between parents rather than destroyed.
///
/// Teardown rule (applied after `reconcile`): any cached `PaneViewController`
/// whose id is no longer in the new tree is dropped from the cache; callers
/// typically trigger `disconnect` on those via the pane's `viewWillDisappear`.
@MainActor
final class PaneSplitFactory {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "pane.reconcile")

    private let registry: LivePaneRegistry
    private let makePane: @MainActor (Conversation.ID) -> PaneViewController

    /// Active pane VCs keyed by Conversation.ID. Updated by `reconcile`.
    private(set) var cache: [Conversation.ID: PaneViewController] = [:]

    init(
        registry: LivePaneRegistry = .shared,
        makePane: @escaping @MainActor (Conversation.ID) -> PaneViewController = { PaneViewController(conversationID: $0) }
    ) {
        self.registry = registry
        self.makePane = makePane
    }

    // MARK: - Reconcile

    /// Reconcile the tree and return the root view controller. Caller embeds
    /// the returned VC's `view` into its container. After `reconcile`, call
    /// `vanishedIDs(from:)` to find panes that were closed.
    @discardableResult
    func reconcile(_ node: PaneNode) -> NSViewController {
        let retained = Set(node.leafIDs)
        let result = build(node)
        // Drop VCs for leaves that vanished. Explicitly disconnect the
        // terminal first so `.native` PTYs get SIGHUP'd synchronously
        // (otherwise they survive until ARC finalizes the view controller).
        let dropped = cache.keys.filter { !retained.contains($0) }
        for id in dropped {
            let pane = cache[id]
            pane?.terminalView.disconnect()
            pane?.view.removeFromSuperview()
            pane?.removeFromParent()
            cache.removeValue(forKey: id)
            registry.unregister(id)
        }
        return result
    }

    // MARK: - Internal recursion

    private func build(_ node: PaneNode) -> NSViewController {
        switch node {
        case .leaf(let id):
            if let existing = cache[id] {
                return existing
            }
            let pane = makePane(id)
            cache[id] = pane
            return pane

        case .split(let axis, let ratio, let children) where children.count == 2:
            let childVCs = children.map { build($0) }
            let split = GapSplitViewController()
            // Prime splitViewItems BEFORE accessing `split.view`/`splitView`.
            // NSSplitViewController's auto-loaded splitView picks up items
            // from `splitViewItems` during its own viewDidLoad — so seeding
            // the array first lets the default load path do the right thing.
            split.splitViewItems = childVCs.map { vc in
                let item = NSSplitViewItem(viewController: vc)
                item.canCollapse = false
                item.minimumThickness = 80
                return item
            }
            // Now trigger view load with items already in place.
            split.splitView.isVertical = (axis == .vertical)
            // Defer setPosition until view is laid out; store the ratio and
            // set it via viewDidLayout via a one-shot helper.
            split.splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            split.splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

            // Apply ratio after first layout pass.
            let clampedRatio = max(0.1, min(0.9, ratio))
            DispatchQueue.main.async { [weak split] in
                guard let split else { return }
                let bounds = split.splitView.bounds
                let divider = split.splitView.isVertical
                    ? bounds.width * clampedRatio
                    : bounds.height * clampedRatio
                split.splitView.setPosition(divider, ofDividerAt: 0)
            }

            return split

        case .split:
            // Malformed tree (children.count != 2). Log and fall back to the
            // first leaf we can find, or a fresh placeholder.
            Self.logger.error("malformed split node; falling back to first leaf")
            if let firstLeaf = node.leafIDs.first {
                return build(.leaf(firstLeaf))
            }
            return NSViewController()
        }
    }
}
