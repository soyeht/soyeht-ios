import AppKit
import os

private final class PaneGridDropView: NSView {
    var onPaneDragUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onPaneDragExited: (() -> Void)?
    var onPaneDragPerformed: ((NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onPaneDragUpdated?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onPaneDragUpdated?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onPaneDragExited?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onPaneDragExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPaneDragPerformed?(sender) ?? false
    }
}

private final class PaneDockOverlayView: NSView {
    private var target: WorkspaceLayout.DockTarget?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = 500
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(target: WorkspaceLayout.DockTarget) {
        self.target = target
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        target = nil
        isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let target else { return }
        let rect = target.rect.insetBy(dx: 4, dy: 4)
        guard rect.width > 8, rect.height > 8 else { return }

        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        let active = MacTheme.accentBlue
        let passiveFill = active.withAlphaComponent(0.12)
        let activeFill = active.withAlphaComponent(0.34)

        for zone in [PaneDockZone.left, .right, .top, .bottom, .center] {
            let zoneRect = self.zoneRect(zone, in: rect)
            let path = NSBezierPath(rect: zoneRect)
            (zone == target.zone ? activeFill : passiveFill).setFill()
            path.fill()
        }

        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        active.withAlphaComponent(0.86).setStroke()
        outline.stroke()

        let activePath = NSBezierPath(rect: zoneRect(target.zone, in: rect).insetBy(dx: 1, dy: 1))
        activePath.lineWidth = 2
        active.setStroke()
        activePath.stroke()
    }

    private func zoneRect(_ zone: PaneDockZone, in rect: CGRect) -> CGRect {
        let edgeWidth = max(36, rect.width * 0.26)
        let edgeHeight = max(36, rect.height * 0.26)
        switch zone {
        case .left:
            return CGRect(x: rect.minX, y: rect.minY, width: min(edgeWidth, rect.width), height: rect.height)
        case .right:
            let width = min(edgeWidth, rect.width)
            return CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)
        case .top:
            let height = min(edgeHeight, rect.height)
            return CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        case .bottom:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(edgeHeight, rect.height))
        case .center:
            return rect.insetBy(dx: min(edgeWidth, rect.width * 0.35), dy: min(edgeHeight, rect.height * 0.35))
        }
    }
}

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
    private let dockOverlay = PaneDockOverlayView()

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

    /// Fired when a pane/header drag is dropped onto this grid. The container
    /// supplies the destination workspace ID; the grid only knows the target
    /// leaf and zone inside its own tree.
    var onPaneDocked: ((
        _ paneID: Conversation.ID,
        _ sourceWorkspaceID: Workspace.ID,
        _ targetPaneID: Conversation.ID,
        _ zone: PaneDockZone
    ) -> Void)?

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
        let root = PaneGridDropView()
        root.wantsLayer = true
        // SXnc2 V2 gutter (matches `paneGrid.fill` in the design).
        root.layer?.backgroundColor = MacTheme.gutter.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false
        root.registerForDraggedTypes([PaneHeaderView.panePasteboardType])
        root.onPaneDragUpdated = { [weak self] info in
            self?.updatePaneDockDrag(info) ?? []
        }
        root.onPaneDragExited = { [weak self] in
            self?.clearPaneDockDrag()
        }
        root.onPaneDragPerformed = { [weak self] info in
            self?.performPaneDockDrop(info) ?? false
        }
        self.view = root
        reconcile()
        installDockOverlay()
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
        if let id = zoomedPaneID, !tree.contains(id) {
            zoomedPaneID = nil
        }
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

    /// Programmatic zoom used by automation/MCP. Unlike the menu toggle, this
    /// always leaves the requested pane zoomed even if another pane was zoomed.
    func zoomPane(_ id: Conversation.ID) {
        guard tree.contains(id) else { return }
        focusedPaneID = id
        zoomedPaneID = id
        reconcile()
        focus(paneID: id)
    }

    func unzoomPane() {
        guard zoomedPaneID != nil else { return }
        zoomedPaneID = nil
        reconcile()
        if let id = focusedPaneID {
            focus(paneID: id)
        }
    }

    func applyTheme() {
        PerfTrace.interval("grid.applyTheme") {
            view.layer?.backgroundColor = MacTheme.gutter.cgColor
            for pane in factory.cache.values {
                pane.applyTheme()
            }
        }
    }

    func synchronizeTerminalSizes(force: Bool = false) {
        for pane in factory.cache.values {
            pane.synchronizeTerminalSizeWithBackend(force: force)
        }
    }

    /// Entry point from the header's right-click "Rename…" menu. Focuses
    /// the pane first so the subsequent sheet is modal to the right window,
    /// then delegates to the host via `onPaneRenameRequested`.
    func requestRenamePane(_ id: Conversation.ID) {
        guard tree.contains(id) else { return }
        focus(paneID: id)
        onPaneRenameRequested?(id)
    }

    @discardableResult
    func takePaneForMove(_ id: Conversation.ID) -> PaneViewController? {
        if focusedPaneID == id {
            focusedPaneID = nil
        }
        if zoomedPaneID == id {
            zoomedPaneID = nil
        }
        return factory.takePaneForMove(id)
    }

    func adoptPaneForMove(_ pane: PaneViewController) {
        factory.adoptPaneForMove(pane)
        wireHeaderActions()
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
        if dockOverlay.superview === view {
            view.addSubview(dockOverlay, positioned: .above, relativeTo: newRoot.view)
        }
        wireHeaderActions()
        assertCacheMatchesTree()
    }

    private func installDockOverlay() {
        guard dockOverlay.superview == nil else { return }
        dockOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dockOverlay)
        NSLayoutConstraint.activate([
            dockOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            dockOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dockOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dockOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        dockOverlay.hide()
    }

    private func updatePaneDockDrag(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let payload = panePayload(from: info),
              let target = dockTarget(for: info, excluding: payload.paneID) else {
            clearPaneDockDrag()
            return []
        }
        dockOverlay.show(target: target)
        return .move
    }

    private func performPaneDockDrop(_ info: NSDraggingInfo) -> Bool {
        defer { clearPaneDockDrag() }
        guard let payload = panePayload(from: info),
              let target = dockTarget(for: info, excluding: payload.paneID) else {
            return false
        }
        onPaneDocked?(payload.paneID, payload.workspaceID, target.paneID, target.zone)
        return true
    }

    private func clearPaneDockDrag() {
        dockOverlay.hide()
    }

    private func panePayload(from info: NSDraggingInfo) -> (paneID: Conversation.ID, workspaceID: Workspace.ID)? {
        guard let string = info.draggingPasteboard.string(forType: PaneHeaderView.panePasteboardType) else {
            return nil
        }
        return PaneHeaderView.decodePanePayload(string)
    }

    private func dockTarget(
        for info: NSDraggingInfo,
        excluding draggedPaneID: Conversation.ID
    ) -> WorkspaceLayout.DockTarget? {
        let point = view.convert(info.draggingLocation, from: nil)
        guard let target = WorkspaceLayout.dockTarget(in: tree, bounds: view.bounds, point: point),
              target.paneID != draggedPaneID else {
            return nil
        }
        return target
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
        guard let command = AppCommandRegistry.command(matching: event, in: .paneGrid) else {
            return false
        }

        switch command.id {
        case .toggleZoomFocusedPane:
            toggleZoomFocusedPane(nil)
        case .focusPaneLeft:
            focusPaneLeft(nil)
        case .focusPaneRight:
            focusPaneRight(nil)
        case .focusPaneDown:
            focusPaneDown(nil)
        case .focusPaneUp:
            focusPaneUp(nil)
        case .swapPaneLeft:
            swapPaneLeft(nil)
        case .swapPaneRight:
            swapPaneRight(nil)
        case .swapPaneDown:
            swapPaneDown(nil)
        case .swapPaneUp:
            swapPaneUp(nil)
        case .rotateFocusedSplit:
            rotateFocusedSplit(nil)
        case .exitZoom where zoomedPaneID != nil:
            exitZoom(nil)
        case .exitZoom:
            return false
        default:
            return false
        }
        return true
    }
}
