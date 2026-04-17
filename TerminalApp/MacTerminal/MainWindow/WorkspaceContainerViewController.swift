import AppKit
import os

/// Container for a single workspace's pane grid. Reads the active layout from
/// `WorkspaceStore`, hosts a `PaneGridController`, and re-applies tree changes
/// back to the store on mutation. Listens for out-of-band changes (e.g. sidebar
/// rename) via `WorkspaceStore.changedNotification` and updates in place.
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

    init(store: WorkspaceStore, workspaceID: Workspace.ID) {
        self.store = store
        self.workspaceID = workspaceID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        self.view = root
        installGrid()

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: WorkspaceStore.changedNotification, object: store
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Grid

    private func installGrid() {
        guard let workspace = store.workspace(workspaceID) else {
            Self.logger.error("no workspace for id \(String(describing: self.workspaceID))")
            return
        }
        let grid = PaneGridController(tree: workspace.layout)
        grid.onTreeMutated = { [weak self] newTree in
            self?.persistTree(newTree)
        }

        addChild(grid)
        grid.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid.view)
        NSLayoutConstraint.activate([
            grid.view.topAnchor.constraint(equalTo: view.topAnchor),
            grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.grid = grid
    }

    // MARK: - Store round-trip

    private func persistTree(_ newTree: PaneNode) {
        guard var ws = store.workspace(workspaceID) else { return }
        guard ws.layout != newTree else { return }
        ws.layout = newTree
        // Update via the store's add(), which replaces by id.
        _ = store.add(ws)
    }

    @objc private func storeChanged() {
        guard let workspace = store.workspace(workspaceID) else { return }
        if grid?.tree != workspace.layout {
            grid?.setTree(workspace.layout)
        }
    }
}
