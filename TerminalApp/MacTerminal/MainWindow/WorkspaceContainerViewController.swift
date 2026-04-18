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
    /// Fired when the grid's last pane is closed. Host (SoyehtMainWindowController)
    /// decides: close the workspace, or beep if it's the only workspace.
    var onWorkspaceWantsToClose: ((Workspace.ID) -> Void)?
    private let statusBar = StatusBarView()

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

        root.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        refreshStatusBar()

        installGrid()

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: WorkspaceStore.changedNotification, object: store
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: ConversationStore.changedNotification, object: nil
        )
    }

    private func refreshStatusBar() {
        guard let convStore = AppEnvironment.conversationStore else {
            statusBar.setServers([])
            return
        }
        // Group active conversations by commander. Remote sessions (`.mirror`)
        // cluster by tmux instance id; local (`.native`) sessions collapse
        // under a single "mac" entry — the Mac itself is the "server" here.
        var byInstance: [String: [Conversation]] = [:]
        let localKey = ProcessInfo.processInfo.hostName
            .components(separatedBy: ".").first ?? "mac"
        for conv in convStore.conversations(in: workspaceID) {
            switch conv.commander {
            case .mirror(let instanceID) where instanceID != "pending":
                byInstance[instanceID, default: []].append(conv)
            case .native(let pid) where pid > 0:
                byInstance[localKey, default: []].append(conv)
            default:
                continue
            }
        }
        let servers: [StatusBarView.Server] = byInstance.map { (instance, convs) in
            let tags = Array(Set(convs.map { $0.agent.displayName })).sorted()
            return .init(name: instance, tags: tags, online: true)
        }.sorted { $0.name < $1.name }
        statusBar.setServers(servers)
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
        grid.onWouldCloseLastPane = { [weak self] in
            guard let self else { return }
            self.onWorkspaceWantsToClose?(self.workspaceID)
        }

        addChild(grid)
        grid.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid.view)
        // Design `Eve85` paneGrid: fill #000000, padding 8. The black shows as
        // an 8pt gutter around each pane, matching the Pencil spec. Bottom
        // anchor attaches to the status bar so the grid sits above it.
        NSLayoutConstraint.activate([
            grid.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            grid.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -8),
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
        refreshStatusBar()
    }
}
