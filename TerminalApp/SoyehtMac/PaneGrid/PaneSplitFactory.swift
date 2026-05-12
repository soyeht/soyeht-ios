import AppKit
import os

/// NSSplitView subclass that draws the theme-derived 8pt pane-grid divider.
@MainActor
final class GapSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 8 }
    override var dividerColor: NSColor { MacTheme.gutter }
    override func drawDivider(in rect: NSRect) {
        MacTheme.gutter.setFill()
        rect.fill()
    }
}

/// Vanilla NSSplitViewController. We used to customize its splitView but that
/// broke `addSplitViewItem` routing — customizations now live in the delegate
/// path or post-factory layout tweaks.
///
/// Fase 1.5 additions:
/// - `initialRatio` is the ratio the factory wants applied on first layout.
///   It's applied exactly once via `viewDidLayout` (replacing the previous
///   `DispatchQueue.main.async` in factory.build, which raced with user drags).
/// - `onRatioChanged` fires only when the user drags the divider (the
///   `NSSplitView.didResizeSubviewsNotification` userInfo contains
///   `NSSplitViewDividerIndex` only for user-initiated resizes, per Apple
///   documentation — window resizes and programmatic `setPosition` are NOT
///   reported with that key). This makes the fire edge trivially correct
///   without a reentrancy flag.
/// - `paneNodePath` is the chain of child indices from the tree root to this
///   split. Passed back with the callback so the grid can update the right
///   split via `PaneNode.settingRatio(atPath:ratio:)`.
@MainActor
final class GapSplitViewController: NSSplitViewController {
    var initialRatio: CGFloat = 0.5
    var paneNodePath: [Int] = []
    var onRatioChanged: (@MainActor (_ path: [Int], _ ratio: CGFloat) -> Void)?
    private var hasAppliedInitialRatio = false
    private var isApplyingInitialRatio = false

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
        // First pass with a valid bounds wins; subsequent layout passes (e.g.
        // window resize) leave the user-dragged divider alone.
        guard !hasAppliedInitialRatio else { return }
        let bounds = splitView.bounds
        guard bounds.width > 0, bounds.height > 0,
              splitView.arrangedSubviews.count == 2 else { return }
        hasAppliedInitialRatio = true
        let clamped = max(0.1, min(0.9, initialRatio))
        let divider = splitView.isVertical
            ? bounds.width * clamped
            : bounds.height * clamped
        isApplyingInitialRatio = true
        splitView.setPosition(divider, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingInitialRatio = false
        }
    }

    @objc private func splitViewResized(_ n: Notification) {
        guard hasAppliedInitialRatio, !isApplyingInitialRatio else { return }
        // Apple docs: NSSplitViewDividerIndex is present ONLY when the
        // resize originated from a user drag of a divider. Window resizes
        // and our own `setPosition` do not set this key.
        guard n.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        guard splitView.arrangedSubviews.count == 2 else { return }
        let bounds = splitView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let first = splitView.arrangedSubviews[0].frame
        let ratio: CGFloat = splitView.isVertical
            ? first.width / bounds.width
            : first.height / bounds.height
        let clamped = max(0.1, min(0.9, ratio))
        onRatioChanged?(paneNodePath, clamped)
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

    /// Reconcile the tree and return the root view controller. Caller embeds
    /// the returned VC's `view` into its container. Drops cached panes that
    /// aren't in `node.leafIDs`. Use `reconcile(render:retaining:)` when the
    /// rendered subtree is narrower than the retained set (Fase 2.4 zoom).
    @discardableResult
    func reconcile(_ node: PaneNode) -> NSViewController {
        reconcile(render: node, retaining: Set(node.leafIDs))
    }

    /// Fase 2.4 — render `render` while keeping `retaining` panes alive in
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
