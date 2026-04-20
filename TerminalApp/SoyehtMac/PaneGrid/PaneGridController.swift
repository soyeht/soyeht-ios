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

    /// Fase 2.4 — while non-nil, the grid renders only this leaf, expanded
    /// to fill the container. The underlying `tree` is untouched so exiting
    /// zoom (`Esc` / ⌘⇧Z again) instantly restores the split layout without
    /// needing to reconstruct it. Ignored if the leaf isn't in `tree`.
    private(set) var zoomedPaneID: Conversation.ID?

    /// What the factory actually renders. When zoomed, collapses to a single
    /// leaf; otherwise mirrors `tree`. `setTree` / `mutate` still write to
    /// `tree`, so the workspace's real layout (persisted by the store)
    /// survives the zoom toggle.
    private var effectiveTree: PaneNode {
        if let id = zoomedPaneID, tree.contains(id) {
            return .leaf(id)
        }
        return tree
    }

    /// Leaf to focus on first appearance, if the tree still contains it.
    /// Set by the container from `Workspace.activePaneID` so the last-focused
    /// pane is restored when a workspace is re-entered (e.g. after quit+
    /// relaunch, tab switch, window reopen). `nil` = fall back to first leaf.
    private var initialFocusedPaneID: Conversation.ID?

    private let factory: PaneSplitFactory
    private var currentRoot: NSViewController?
    private var keyEventMonitor: Any?

    // Called when the tree is mutated by a pane action (split/close). The
    // host window controller should persist the new tree to WorkspaceStore
    // and re-apply via `setTree(_:)`.
    var onTreeMutated: ((PaneNode) -> Void)?

    /// Fase 2.3 — fired for ratio-only tree changes (divider drags). Distinct
    /// from `onTreeMutated` so the host can skip undo registration for the
    /// high-frequency ratio stream (one fire per NSSplitView drag tick).
    /// Falls back to `onTreeMutated` if unwired.
    var onRatioTreeChanged: ((PaneNode) -> Void)?

    // Called when the focused pane should be closed and the tree reduces to
    // a single leaf (or empty). Host decides whether to close the workspace
    // or the whole window.
    var onWouldCloseLastPane: (() -> Void)?

    // Fired every time the focused leaf changes (user click, neighbor
    // navigation, tree mutation fallback, or programmatic focusPane).
    // Container controller mirrors this to `WorkspaceStore.setActivePane`
    // so sidebar + restoration stay in sync with the real first-responder.
    var onPaneFocused: ((Conversation.ID) -> Void)?

    /// Fired when a pane header's right-click "Rename…" menu is chosen.
    /// Host (container → window controller) presents a sheet and updates
    /// `ConversationStore`. Grid itself doesn't know the store.
    var onPaneRenameRequested: ((Conversation.ID) -> Void)?

    // MARK: - Init

    init(
        tree: PaneNode,
        factory: PaneSplitFactory? = nil,
        initialFocusedPaneID: Conversation.ID? = nil
    ) {
        self.tree = tree
        self.factory = factory ?? PaneSplitFactory()
        self.initialFocusedPaneID = initialFocusedPaneID
        super.init(nibName: nil, bundle: nil)
        // Hook the split factory so user drags propagate back as ratio-only
        // tree updates. Uses `applyRatioChange` (not `mutate`) because the
        // NSSplitView has ALREADY moved the divider visually; reconciling
        // would rebuild the split VC mid-drag and cause a jump. We only
        // persist the new tree to the store.
        self.factory.onRatioChanged = { [weak self] path, ratio in
            self?.applyRatioChange(atPath: path, ratio: ratio)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // SXnc2 V2 gutter (matches `paneGrid.fill` in the design).
        root.layer?.backgroundColor = MacTheme.gutter.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root
        reconcile()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
        // First appearance: prefer the persisted `activePaneID` (passed in via
        // `initialFocusedPaneID`) if the leaf still exists in the live tree.
        // Fallback: first leaf. The selector lives in `WorkspaceLayout` so the
        // AppKit-free test target can cover it directly.
        if focusedPaneID == nil,
           let picked = WorkspaceLayout.selectInitialFocus(
                preferred: initialFocusedPaneID,
                available: tree.leafIDs
           ) {
            focus(paneID: picked)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyMonitor()
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

    /// Public entry point for programmatic focus (e.g. sidebar row click).
    /// Delegates to the same internal focus path, so `onPaneFocused` fires
    /// and container mirrors to `WorkspaceStore.setActivePane` — single
    /// source of truth, regardless of whether the click came from a pane
    /// body or an external view.
    func focusPane(_ id: Conversation.ID) {
        guard tree.contains(id) else { return }
        focus(paneID: id)
    }

    /// Entry point from the header's right-click "Rename…" menu. Focuses
    /// the pane first so the subsequent sheet is modal to the right window,
    /// then delegates to the host via `onPaneRenameRequested`.
    func requestRenamePane(_ id: Conversation.ID) {
        guard tree.contains(id) else { return }
        focus(paneID: id)
        onPaneRenameRequested?(id)
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

    /// Fase 2.4 — toggle fullscreen of the focused pane. Leaves the tree
    /// intact; only changes what the factory renders. Menu item binds this
    /// to `⌘⇧Z`. No-op if there's no focused pane (nothing to zoom into).
    @IBAction func toggleZoomFocusedPane(_ sender: Any?) {
        if zoomedPaneID != nil {
            zoomedPaneID = nil
        } else if let focused = focusedPaneID, tree.contains(focused) {
            zoomedPaneID = focused
        } else {
            return
        }
        reconcile()
        // Re-focus the pane so the terminal view stays the first responder
        // regardless of which direction the zoom toggle went.
        if let id = focusedPaneID {
            focus(paneID: id)
        }
    }

    /// Explicit exit (Esc). No-op if not zoomed.
    @IBAction func exitZoom(_ sender: Any?) {
        guard zoomedPaneID != nil else { return }
        zoomedPaneID = nil
        reconcile()
        if let id = focusedPaneID { focus(paneID: id) }
    }

    // Fase 2.5 — swap focused pane with its neighbor in the given direction,
    // and rotate the axis of the focused pane's split. Use the existing
    // centroid-based neighbor finder so "left/right/up/down" semantics match
    // ⌘⌥arrow focus navigation.

    @IBAction func swapPaneLeft(_ sender: Any?)  { swapNeighbor(.left) }
    @IBAction func swapPaneRight(_ sender: Any?) { swapNeighbor(.right) }
    @IBAction func swapPaneUp(_ sender: Any?)    { swapNeighbor(.up) }
    @IBAction func swapPaneDown(_ sender: Any?)  { swapNeighbor(.down) }

    @IBAction func rotateFocusedSplit(_ sender: Any?) {
        guard let focused = focusedPaneID else { return }
        mutate { $0.rotatingSplit(containing: focused) }
    }

    private func swapNeighbor(_ direction: WorkspaceLayout.Direction) {
        guard let focused = focusedPaneID else { return }
        guard let neighbor = WorkspaceLayout.neighbor(
            of: focused, in: tree, bounds: view.bounds, direction: direction
        ) else { return }
        mutate { $0.swap(focused, with: neighbor) }
        // Keep focus on the same pane (it moved to neighbor's old slot).
        focus(paneID: focused)
    }

    // MARK: - Private

    /// Apply a user-driven ratio change without reconciling. The split view
    /// has already moved the divider visually; we just update the in-memory
    /// tree and persist via `onTreeMutated`. Crucially does NOT call
    /// `reconcile()` — reconciling rebuilds the split controllers fresh,
    /// which would visually "snap" mid-drag. Structure (leafIDs) is
    /// unchanged; only ratios differ, so skipping reconcile is safe.
    private func applyRatioChange(atPath path: [Int], ratio: CGFloat) {
        let newTree = tree.settingRatio(atPath: path, ratio: ratio)
        guard newTree != tree else { return }
        tree = newTree
        // Ratio-only change: host skips undo registration to avoid flooding
        // the undo stack with one entry per drag tick. Falls back to the
        // structural callback for hosts that haven't opted in.
        if let cb = onRatioTreeChanged {
            cb(newTree)
        } else {
            onTreeMutated?(newTree)
        }
    }

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

        // When zoomed, we render only the focused leaf but RETAIN the full
        // tree's panes in the factory cache — so unzooming instantly brings
        // back the other panes with their WebSockets alive.
        let newRoot = factory.reconcile(
            render: effectiveTree,
            retaining: Set(tree.leafIDs)
        )
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
        // Cache must hold every live leaf. When zoomed, it also equals
        // `leaves` because we pass `retaining: leaves` to the factory; the
        // hidden panes just sit off-screen (detached from the view graph)
        // until unzoom. The previous `==` check still holds.
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
        let changed = (focusedPaneID != id)
        focusedPaneID = id
        for (paneID, pane) in factory.cache {
            pane.setFocused(paneID == id)
        }
        if let pane = factory.cache[id] {
            pane.view.window?.makeFirstResponder(pane.terminalView)
        }
        // Fire only on real transitions so we don't thrash setActivePane on
        // redundant refocus calls (reconcile paths re-focus the same leaf).
        if changed { onPaneFocused?(id) }
    }

    private func focusNeighbor(_ direction: WorkspaceLayout.Direction) {
        guard let id = focusedPaneID else { return }
        let bounds = view.bounds
        guard let neighbor = WorkspaceLayout.neighbor(
            of: id, in: tree, bounds: bounds, direction: direction
        ) else { return }
        focus(paneID: neighbor)
    }

    private func installKeyMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isFirstResponderInsideGrid else { return event }
            if self.handleGridShortcut(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private var isFirstResponderInsideGrid: Bool {
        guard let firstResponder = view.window?.firstResponder as? NSView else {
            return false
        }
        return firstResponder === view || firstResponder.isDescendant(of: view)
    }

    private func handleGridShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if let undoManager = view.window?.undoManager, undoManager.canRedo {
                undoManager.redo()
            } else {
            toggleZoomFocusedPane(nil)
            }
            return true
        }
        if flags == [.command, .shift] {
            switch event.keyCode {
            case 123: focusPaneLeft(nil);  return true
            case 124: focusPaneRight(nil); return true
            case 125: focusPaneDown(nil);  return true
            case 126: focusPaneUp(nil);    return true
            default: break
            }
        }
        if flags == [.option, .shift] {
            switch event.keyCode {
            case 123:
                swapPaneLeft(nil)
                return true
            case 124:
                swapPaneRight(nil)
                return true
            case 125:
                swapPaneDown(nil)
                return true
            case 126:
                swapPaneUp(nil)
                return true
            case 15:
                rotateFocusedSplit(nil)
                return true
            default:
                break
            }
        }
        if event.keyCode == 53, zoomedPaneID != nil {
            exitZoom(nil)
            return true
        }
        return false
    }
}
