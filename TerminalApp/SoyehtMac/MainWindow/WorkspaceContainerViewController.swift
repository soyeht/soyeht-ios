import AppKit
import os

/// Container for a single workspace's pane grid. Reads the active layout from
/// `WorkspaceStore`, hosts a `PaneGridController`, and re-applies tree changes
/// back to the store on mutation. Listens for out-of-band changes (e.g. sidebar
/// rename) via an `ObservationTracker` loop on `WorkspaceStore` (Fase 3.1) and
/// updates in place.
///
/// Phase 4 scope: render a single workspace. Phase 5 adds the titlebar tab
/// bar; Phase 10 wires broader multi-window coordination.
@MainActor
final class WorkspaceContainerViewController: NSViewController {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "workspace.container")

    // MARK: - Wiring

    let store: WorkspaceStore
    private(set) var workspaceID: Workspace.ID
    private(set) var grid: PaneGridController?
    var gridController: PaneGridController? { grid }
    /// Fired when the grid's last pane is closed. Host (SoyehtMainWindowController)
    /// decides: close the workspace, or beep if it's the only workspace.
    var onWorkspaceWantsToClose: ((Workspace.ID) -> Void)?
    /// Fired by `PaneHeaderView`'s "Rename…" menu. Host presents a modal
    /// NSAlert and calls `ConversationStore.rename(id:to:)` on confirm.
    var onPaneRenameRequested: ((Conversation.ID) -> Void)?
    /// Public anchor for overlays (floating sidebar) to pin their bottom
    /// edge against. SXnc2 doesn't show a status bar, so this resolves to
    /// the container's own bottom edge. Preserved as a named accessor so
    /// the chrome controller doesn't reach into `view` directly.
    var statusBarTopAnchor: NSLayoutYAxisAnchor { view.bottomAnchor }

    private var workspaceObservationToken: ObservationToken?

    init(store: WorkspaceStore, workspaceID: Workspace.ID) {
        self.store = store
        self.workspaceID = workspaceID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // SXnc2 V2: gutter between panes, sourced from the active theme and
        // visible through the grid insets.
        root.layer?.backgroundColor = MacTheme.gutter.cgColor
        self.view = root

        installGrid()

        // Fase 3.1 — observe only the workspace properties the handler reads
        // (`layout`, `activePaneID`). ConversationStore observation was
        // dropped because `storeChanged()` never read a conversation.
        workspaceObservationToken = ObservationTracker.observe(self,
            reads: { $0.observationReads() },
            onChange: { $0.storeChanged() }
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reapplyPersistedFocus()
    }

    deinit {
        // `ObservationToken.deinit` also sets `isActive = false`; the explicit
        // cancel here is documentation for future maintainers.
        MainActor.assumeIsolated {
            workspaceObservationToken?.cancel()
        }
    }

    /// Observed surface of `storeChanged` — must cover every store property
    /// the handler reads. If you add a read in `storeChanged`, mirror it here.
    private func observationReads() {
        guard let ws = store.workspace(workspaceID) else { return }
        _ = ws.layout
        _ = ws.activePaneID
    }

    // MARK: - Grid

    private func installGrid() {
        guard let workspace = store.workspace(workspaceID) else {
            Self.logger.error("no workspace for id \(String(describing: self.workspaceID))")
            return
        }
        // Fase 1.3: seed `initialFocusedPaneID` from the persisted
        // `activePaneID` so the last-focused pane is restored on first
        // appearance (quit+relaunch, first time a workspace is visited).
        // The grid itself re-validates the id against `tree.leafIDs` before
        // applying — stale ids (pane closed in another window) fall back to
        // the first leaf without crashing.
        let grid = PaneGridController(
            tree: workspace.layout,
            initialFocusedPaneID: workspace.activePaneID
        )
        grid.onTreeMutated = { [weak self] newTree in
            self?.persistTree(newTree, undoable: true)
        }
        grid.onRatioTreeChanged = { [weak self] newTree in
            // Divider drags produce many ticks; no undo (would flood the stack).
            self?.persistTree(newTree, undoable: false)
        }
        grid.onWouldCloseLastPane = { [weak self] in
            guard let self else { return }
            self.onWorkspaceWantsToClose?(self.workspaceID)
        }
        // Mirror focus changes into the store so `ws.activePaneID` stays
        // in lockstep with the real first-responder. Sidebar overlay and
        // future restoration paths read activePaneID as source of truth.
        grid.onPaneFocused = { [weak self] paneID in
            guard let self else { return }
            self.store.setActivePane(workspaceID: self.workspaceID, paneID: paneID)
        }
        grid.onPaneRenameRequested = { [weak self] paneID in
            self?.onPaneRenameRequested?(paneID)
        }

        addChild(grid)
        grid.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid.view)
        // SXnc2 `paneGrid` sits edge-to-edge with 1pt gutters between panes
        // (painted by the grid itself). No outer padding — the rounded-window
        // clip on `WindowChromeViewController` gives the visual inset.
        NSLayoutConstraint.activate([
            grid.view.topAnchor.constraint(equalTo: view.topAnchor),
            grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.grid = grid
    }

    // MARK: - Store round-trip

    private func persistTree(_ newTree: PaneNode, undoable: Bool) {
        guard let ws = store.workspace(workspaceID), ws.layout != newTree else { return }
        // `setLayout` keeps `ws.conversations` in sync with `layout.leafIDs`
        // on every mutation — the historical `store.add(ws)` path wrote
        // only `layout`, leaving `conversations` stale and tab counts,
        // restart, and teardown disagreeing about which panes existed.
        let undoManager = undoable ? view.window?.undoManager : nil
        store.setLayout(workspaceID, layout: newTree, undoManager: undoManager)
    }

    func reapplyPersistedFocus() {
        guard let workspace = store.workspace(workspaceID),
              let grid else { return }
        let target = WorkspaceLayout.selectInitialFocus(
            preferred: workspace.activePaneID,
            available: workspace.layout.leafIDs
        )
        guard let target else { return }
        // Single synchronous call — the historical `DispatchQueue.main.async`
        // retry was a defense against a race that no longer reproduces with
        // the cached-container model: by the time this runs, the container's
        // view is already in `chromeVC.view` and `pane.view.window` resolves,
        // so `makeFirstResponder` sticks on the first try.
        PerfTrace.interval("focus.apply") {
            grid.focusPane(target)
        }
    }

    func applyTheme() {
        PerfTrace.interval("container.applyTheme") {
            view.layer?.backgroundColor = MacTheme.gutter.cgColor
            grid?.applyTheme()
        }
    }

    private func storeChanged() {
        guard let workspace = store.workspace(workspaceID) else { return }
        if grid?.tree != workspace.layout {
            grid?.setTree(workspace.layout)
        }
        guard view.window != nil, view.superview != nil else { return }
        let target = WorkspaceLayout.selectInitialFocus(
            preferred: workspace.activePaneID,
            available: workspace.layout.leafIDs
        )
        if let target, grid?.focusedPaneID != target {
            grid?.focusPane(target)
        }
    }
}
