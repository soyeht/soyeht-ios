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
        guard let id = focusedPaneID else {
            view.window?.performClose(nil)
            return
        }
        if tree.leafCount <= 1 {
            onWouldCloseLastPane?()
            view.window?.performClose(nil)
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
        let newRoot = factory.reconcile(tree)
        guard newRoot !== currentRoot else {
            // Same root (unlikely once trees mutate). Still refresh bindings.
            wireHeaderActions()
            return
        }
        // Swap root into self.view.
        currentRoot?.view.removeFromSuperview()
        currentRoot?.removeFromParent()
        addChild(newRoot)
        newRoot.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newRoot.view)
        NSLayoutConstraint.activate([
            newRoot.view.topAnchor.constraint(equalTo: view.topAnchor),
            newRoot.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newRoot.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newRoot.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentRoot = newRoot
        wireHeaderActions()
    }

    /// After every reconcile, reattach header callbacks so they hit THIS grid
    /// even if a pane was cached from an earlier grid.
    private func wireHeaderActions() {
        for (id, pane) in factory.cache {
            pane.header.onSplitVerticalTapped = { [weak self] in
                self?.focus(paneID: id)
                self?.splitPaneVertical(nil)
            }
            pane.header.onSplitHorizontalTapped = { [weak self] in
                self?.focus(paneID: id)
                self?.splitPaneHorizontal(nil)
            }
            pane.header.onCloseTapped = { [weak self] in
                self?.focus(paneID: id)
                self?.closePaneOrWindow(nil)
            }
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
