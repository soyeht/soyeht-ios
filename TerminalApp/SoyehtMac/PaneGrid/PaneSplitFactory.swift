import AppKit
import os

// NOTE: Do not subclass/replace NSSplitViewController's splitView here — a
// custom splitView (even installed before super.loadView()) breaks
// addSplitViewItem routing and the pane area renders empty. The neo pane gap
// comes from per-pane card insets in `PaneViewController` instead.

/// Vanilla NSSplitViewController. We used to customize its splitView but that
/// broke `addSplitViewItem` routing — customizations now live in the delegate
/// path or post-factory layout tweaks.
///
/// Phase 1.5 additions:
/// - `initialRatio` is the ratio the factory wants applied on first layout.
///   It is also kept as this split's target ratio and re-applied whenever the
///   split's own axis length changes, so window resizes preserve pane
///   proportions instead of letting nested `NSSplitView`s absorb the delta in
///   one branch.
/// - `onRatioChanged` fires only when the user drags the divider. AppKit can
///   include `NSSplitViewDividerIndex` during autosizing, so the handler also
///   requires the split's own axis length to be unchanged. Window resizes are
///   corrected back to `targetRatio` instead of being persisted as user edits.
/// - `paneNodePath` is the chain of child indices from the tree root to this
///   split. Passed back with the callback so the grid can update the right
///   split via `PaneNode.settingRatio(atPath:ratio:)`.
@MainActor
final class GapSplitViewController: NSSplitViewController {
    var initialRatio: CGFloat = 0.5 {
        didSet { targetRatio = Self.clampRatio(initialRatio) }
    }
    var paneNodePath: [Int] = []
    var onRatioChanged: (@MainActor (_ path: [Int], _ ratio: CGFloat) -> Void)?
    private var targetRatio: CGFloat = 0.5
    private var hasAppliedInitialRatio = false
    private var isApplyingRatio = false
    private var lastAppliedSplitLength: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewResized(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyTargetRatioIfNeeded(force: !hasAppliedInitialRatio)
    }

    private func applyTargetRatioIfNeeded(force: Bool = false) {
        let bounds = splitView.bounds
        guard bounds.width > 0, bounds.height > 0,
              splitView.arrangedSubviews.count == 2 else { return }
        let splitLength = splitView.isVertical ? bounds.width : bounds.height
        guard force || lastAppliedSplitLength.map({ abs($0 - splitLength) > 0.5 }) == true else {
            return
        }

        hasAppliedInitialRatio = true
        lastAppliedSplitLength = splitLength
        targetRatio = Self.clampRatio(targetRatio)
        let divider = splitView.isVertical
            ? bounds.width * targetRatio
            : bounds.height * targetRatio
        isApplyingRatio = true
        splitView.setPosition(divider, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingRatio = false
        }
    }

    /// Widen the divider's effective hit/cursor area without making the
    /// drawn pixel band any thicker. The drawn divider stays 8pt (clean
    /// look) but the user can grab anywhere within ±4pt of it — total
    /// 16pt grab zone, same as Xcode/VS Code. AppKit also routes the
    /// resize cursor to this expanded rect automatically.
    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        let extra: CGFloat = 4
        return splitView.isVertical
            ? drawnRect.insetBy(dx: -extra, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -extra)
    }

    @objc private func splitViewResized(_ n: Notification) {
        guard hasAppliedInitialRatio, !isApplyingRatio else { return }
        guard n.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        guard splitView.arrangedSubviews.count == 2 else { return }
        let bounds = splitView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let splitLength = splitView.isVertical ? bounds.width : bounds.height
        if let lastAppliedSplitLength, abs(lastAppliedSplitLength - splitLength) > 0.5 {
            DispatchQueue.main.async { [weak self] in
                self?.applyTargetRatioIfNeeded(force: true)
            }
            return
        }

        let first = splitView.arrangedSubviews[0].frame
        let ratio: CGFloat = splitView.isVertical
            ? first.width / bounds.width
            : first.height / bounds.height
        let clamped = Self.clampRatio(ratio)
        targetRatio = clamped
        lastAppliedSplitLength = splitLength
        onRatioChanged?(paneNodePath, clamped)
    }

    private static func clampRatio(_ ratio: CGFloat) -> CGFloat {
        max(0.1, min(0.9, ratio))
    }
}

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

    /// Fired when a user drags any divider. The callback gets the split's
    /// path (chain of child indices from root) and the new ratio. Wired by
    /// `PaneGridController` to a ratio-only tree update (no reconcile, so
    /// the user's drag isn't visually interrupted mid-gesture).
    var onRatioChanged: (@MainActor (_ path: [Int], _ ratio: CGFloat) -> Void)?

    init(
        registry: LivePaneRegistry? = nil,
        makePane: @escaping @MainActor (Conversation.ID) -> PaneViewController = { PaneViewController(conversationID: $0) }
    ) {
        self.registry = registry ?? .shared
        self.makePane = makePane
    }

    // MARK: - Reconcile

    /// Remove a pane from this factory without disconnecting its terminal.
    /// Used by cross-workspace moves, where the same `PaneViewController`
    /// instance is adopted by another grid so scrollback, WebSocket/local PTY,
    /// and terminal state survive the move intact.
    @discardableResult
    func takePaneForMove(_ id: Conversation.ID) -> PaneViewController? {
        guard let pane = cache.removeValue(forKey: id) else { return nil }
        pane.beginMoveBetweenGrids()
        pane.view.removeFromSuperview()
        if pane.parent != nil {
            pane.removeFromParent()
        }
        return pane
    }

    /// Seed this factory with an already-live pane before the destination
    /// grid reconciles a layout containing that leaf.
    func adoptPaneForMove(_ pane: PaneViewController) {
        let id = pane.conversationID
        if let existing = cache[id], existing !== pane {
            existing.terminalView.disconnect()
            existing.view.removeFromSuperview()
            if existing.parent != nil {
                existing.removeFromParent()
            }
            registry.unregister(id, pane: existing)
        }
        cache[id] = pane
        registry.register(id, pane: pane)
        pane.endMoveBetweenGrids()
    }

    /// Reconcile the tree and return the root view controller. Caller embeds
    /// the returned VC's `view` into its container. Drops cached panes that
    /// aren't in `node.leafIDs`. Use `reconcile(render:retaining:)` when the
    /// rendered subtree is narrower than the retained set (Phase 2.4 zoom).
    @discardableResult
    func reconcile(_ node: PaneNode) -> NSViewController {
        reconcile(render: node, retaining: Set(node.leafIDs))
    }

    /// Phase 2.4 - render `render` while keeping `retaining` panes alive in
    /// the cache. `retaining` must be a superset of `render.leafIDs`; panes
    /// outside `retaining` are disconnected and dropped. Used by zoom/
    /// maximize so hidden panes keep their WebSocket + scrollback while
    /// only the focused pane fills the container view.
    ///
    /// Panes that are in `retaining` but NOT in `render.leafIDs` are detached
    /// from their parent view (removed from superview/parent) so they don't
    /// render, but their `PaneViewController` instance (and the terminal
    /// session it owns) stays in the cache. A subsequent `reconcile(fullTree)`
    /// re-attaches them where they belong.
    @discardableResult
    func reconcile(render: PaneNode, retaining retained: Set<Conversation.ID>) -> NSViewController {
        let result = build(render, path: [])
        // Detach any cached panes that aren't part of the rendered subtree —
        // they'd otherwise stay in the view hierarchy as orphans under the
        // previous split's parent. Keeping them in `cache` is what preserves
        // their terminal session across unzoom.
        let renderedLeaves = Set(render.leafIDs)
        for (id, pane) in cache where !renderedLeaves.contains(id) && retained.contains(id) {
            pane.view.removeFromSuperview()
            if pane.parent != nil { pane.removeFromParent() }
        }
        // Drop VCs for leaves that vanished entirely (not in `retained`).
        // Explicitly disconnect the terminal first so `.native` PTYs get
        // SIGHUP'd synchronously.
        let dropped = cache.keys.filter { !retained.contains($0) }
        for id in dropped {
            guard let pane = cache[id] else { continue }
            pane.prepareForClose()
            pane.view.removeFromSuperview()
            pane.removeFromParent()
            cache.removeValue(forKey: id)
            registry.unregister(id, pane: pane)
        }
        return result
    }

    // MARK: - Internal recursion

    private func build(_ node: PaneNode, path: [Int]) -> NSViewController {
        switch node {
        case .leaf(let id):
            if let existing = cache[id] {
                return existing
            }
            let pane = makePane(id)
            cache[id] = pane
            return pane

        case .split(let axis, let ratio, let children) where children.count == 2:
            let childVCs = children.enumerated().map { (idx, child) in
                build(child, path: path + [idx])
            }
            let split = GapSplitViewController()
            split.paneNodePath = path
            split.initialRatio = ratio
            split.onRatioChanged = { [weak self] path, newRatio in
                self?.onRatioChanged?(path, newRatio)
            }
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
            split.splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            split.splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
            // The initialRatio is applied in GapSplitViewController.viewDidLayout,
            // which runs exactly once after bounds become valid — replaces the
            // previous DispatchQueue.main.async setPosition that raced with
            // user drags arriving before the async fired.
            return split

        case .split:
            // Malformed tree (children.count != 2). Log and fall back to the
            // first leaf we can find, or a fresh placeholder.
            Self.logger.error("malformed split node; falling back to first leaf")
            if let firstLeaf = node.leafIDs.first {
                return build(.leaf(firstLeaf), path: path)
            }
            return NSViewController()
        }
    }
}
