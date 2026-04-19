import AppKit
import os

/// Root controller for a workspace's pane tree. Owns a `PaneSplitFactory`,
/// renders a `PaneNode` via its reconciler, tracks the currently focused
/// leaf via `focusedPaneID`, and routes `@IBAction`s from menus / header
/// buttons down to workspace-level mutations.
///
/// Phase 3 scope: render the tree, handle split/close/focus-neighbor, keep
/// the green-border + first-responder invariant. Workspace persistence lives
/// in `WorkspaceStore` (Phase 1); restoration is Phase 14.
@MainActor
final class PaneGridController: NSViewController {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "pane.grid")

    // MARK: - State

    private(set) var tree: PaneNode
    private(set) var focusedPaneID: Conversation.ID?

    private let factory: PaneSplitFactory
    private var currentRoot: NSViewController?

    // Called when the tree is mutated by a pane action (split/close). The
    // host window controller should persist the new tree to WorkspaceStore
    // and re-apply via `setTree(_:)`.
    var onTreeMutated: ((PaneNode) -> Void)?

    // Called when the focused pane should be closed and the tree reduces to
    // a single leaf (or empty). Host decides whether to close the workspace
    // or the whole window.
    var onWouldCloseLastPane: (() -> Void)?

    // MARK: - Init

    init(tree: PaneNode, factory: PaneSplitFactory? = nil) {
        self.tree = tree
        self.factory = factory ?? PaneSplitFactory()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root
        reconcile()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Default focus to the first leaf on first appearance.
        if focusedPaneID == nil, let first = tree.leafIDs.first {
            focus(paneID: first)
        }
    }

    // MARK: - Public API

    /// Replace the tree (e.g. after a sibling window mutated the workspace).
    /// Reconciles in-place; panes whose ids survive are preserved.
    func setTree(_ newTree: PaneNode) {
        tree = newTree
        reconcile()
        if let id = focusedPaneID, !tree.contains(id) {
            focusedPaneID = tree.leafIDs.first
            if let id = focusedPaneID { focus(paneID: id) }
        }
    }

    /// Hook for `PaneViewController` to announce it gained focus (click or
    /// header tap). Grid updates borders + stores `focusedPaneID`.
    func paneDidBecomeFocused(_ id: Conversation.ID) {
        focus(paneID: id)
    }

    /// Called by a pane header's `|` button or the menu. Splits the focused
    /// leaf vertically.
    @IBAction func splitPaneVertical(_ sender: Any?) {
        guard let id = focusedPaneID else { return }
        mutate { $0.split(target: id, new: UUID(), axis: .vertical) }
    }

    @IBAction func splitPaneHorizontal(_ sender: Any?) {
        guard let id = focusedPaneID else { return }
        mutate { $0.split(target: id, new: UUID(), axis: .horizontal) }
    }

    @IBAction func closePaneOrWindow(_ sender: Any?) {
        // Kept for storyboard/menu compatibility (Main.storyboard:323).
        // Behavior now delegates to `closeFocusedPane` — closing the last
        // pane does NOT tear down the window; host decides what "last pane"
        // means via `onWouldCloseLastPane` (typically close the workspace).
        closeFocusedPane(sender)
    }

    /// Reduce the tree by the currently focused leaf. If it's the last
    /// leaf in this grid, fire `onWouldCloseLastPane` and let the host
    /// (WorkspaceContainerViewController → SoyehtMainWindowController)
    /// decide whether to close the workspace, fall back to empty-state,
    /// or close the window.
    @IBAction func closeFocusedPane(_ sender: Any?) {
        guard let id = focusedPaneID else {
            // No focus → treat as "host, decide": workspaces with zero live
            // panes can still own a tab; emit the hook instead of performing
            // a window close here.
            onWouldCloseLastPane?()
            return
        }
        if tree.leafCount <= 1 {
            onWouldCloseLastPane?()
            return
        }
        mutate { $0.closing(id) ?? .leaf(id) }
    }

    @IBAction func focusPaneLeft(_ sender: Any?)  { focusNeighbor(.left) }
    @IBAction func focusPaneRight(_ sender: Any?) { focusNeighbor(.right) }
    @IBAction func focusPaneUp(_ sender: Any?)    { focusNeighbor(.up) }
    @IBAction func focusPaneDown(_ sender: Any?)  { focusNeighbor(.down) }

    // MARK: - Private

    private func mutate(_ transform: (PaneNode) -> PaneNode) {
        let newTree = transform(tree)
        guard newTree != tree else { return }
        tree = newTree
        reconcile()
        onTreeMutated?(newTree)
        // Refocus the previously-focused id if it still exists; else fall
        // back to the first leaf.
        if let id = focusedPaneID, tree.contains(id) {
            focus(paneID: id)
        } else if let first = tree.leafIDs.first {
            focus(paneID: first)
        }
    }

    private func reconcile() {
        // IMPORTANT: detach the OLD root cleanly BEFORE the factory builds
        // the new tree. When a leaf is promoted into a split, the factory
        // calls `addSplitViewItem` on the freshly-created GapSplit, which
        // reparents the existing `PaneViewController` — but AppKit does
        // NOT always move the PaneVC's *view* at that moment (it's lazy).
        // If we leave the old view attached to `self.view` and later add
        // the new root, AppKit sees two overlapping subviews with
        // ambiguous layout and the window renders as a black void.
        //
        // Removing the view + detaching from `children` here guarantees the
        // factory starts from a clean slate: it grabs the cached PaneVC,
        // re-attaches it to the split (as both a child and a subview of
        // the split's splitView), and we then install the new root as the
        // sole occupant of `self.view`.
        if let old = currentRoot {
            old.view.removeFromSuperview()
            if old.parent === self {
                old.removeFromParent()
            }
        }

        let newRoot = factory.reconcile(tree)
        guard newRoot !== currentRoot else {
            wireHeaderActions()
            return
        }
        addChild(newRoot)
        // NSSplitViewController manages its splitView's sizing via an
        // autoresizing mask internally — mixing in our own top/leading/
        // trailing/bottom constraints triggers
        // `LAYOUT_CONSTRAINTS_NOT_SATISFIABLE` and the whole pane area
        // renders empty. Use autoresizing + frame so the root auto-sizes
        // with the grid's view.
        newRoot.view.translatesAutoresizingMaskIntoConstraints = true
        newRoot.view.autoresizingMask = [.width, .height]
        newRoot.view.frame = view.bounds
        view.addSubview(newRoot.view)
        currentRoot = newRoot
        wireHeaderActions()
        assertCacheMatchesTree()
    }

    /// DEBUG invariant: after every reconcile the factory cache must hold
    /// exactly one PaneViewController per leaf in the live tree — no more,
    /// no less. Drift here is the historical source of "button works on
    /// pane X but not pane Y" (a closure captured an `id` that had been
    /// evicted from the cache). Runs at every reconcile entry point
    /// (`loadView`, `setTree`, `mutate`) so notification-observer paths
    /// (`WorkspaceStore.changedNotification`) are covered too.
    private func assertCacheMatchesTree() {
        #if DEBUG
        let cached = Set(factory.cache.keys)
        let leaves = Set(tree.leafIDs)
        assert(cached == leaves,
               "PaneGridController drift: cache=\(cached) vs tree=\(leaves)")
        #endif
    }

    /// After every reconcile, reattach the focus-request hook so clicks on
    /// a pane's body/header migrate focus to that pane.
    ///
    /// The header's split/close button callbacks are **owned by
    /// `PaneViewController.wireHeaderActions`** (via `dispatchToGrid`,
    /// which calls `paneDidBecomeFocused(conversationID)` on the pane's
    /// own id before dispatching the action). Previously this grid also
    /// overwrote those callbacks with captures from a `for (id, pane) in
    /// factory.cache` loop — any drift between the cache and the live
    /// tree made the captured `id` point at a pane that no longer
    /// existed, producing the "button works in one pane but not another"
    /// bug. Single source of truth now lives in the pane itself.
    private func wireHeaderActions() {
        for (_, pane) in factory.cache {
            pane.onFocusRequested = { [weak self] id in
                self?.focus(paneID: id)
            }
        }
    }

    private func focus(paneID id: Conversation.ID) {
        focusedPaneID = id
        for (paneID, pane) in factory.cache {
            pane.setFocused(paneID == id)
        }
        if let pane = factory.cache[id] {
            pane.view.window?.makeFirstResponder(pane.terminalView)
        }
    }

    private func focusNeighbor(_ direction: WorkspaceLayout.Direction) {
        guard let id = focusedPaneID else { return }
        let bounds = view.bounds
        guard let neighbor = WorkspaceLayout.neighbor(
            of: id, in: tree, bounds: bounds, direction: direction
        ) else { return }
        focus(paneID: neighbor)
    }
}
