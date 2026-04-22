import AppKit
import SoyehtCore

/// Horizontal stack of workspace tabs + the "+" add-workspace button,
/// hosted as an `NSToolbarItem` view so everything lives on a single
/// titlebar row (SXnc2 `Tc4Ed`).
///
/// Previously this logic lived in `WorkspaceTitlebarAccessoryController`
/// as an `NSTitlebarAccessoryViewController` with `.bottom` placement —
/// that produced a second row below the titlebar, which the design
/// explicitly collapses. Extracting to a plain view lets the toolbar own
/// it on the same strip as the sidebar / bell / new-conversation items.
@MainActor
final class WorkspaceTabsView: NSView {

    // MARK: - Callbacks

    var onWorkspaceActivated: ((Workspace.ID) -> Void)?
    var onAddWorkspace: (() -> Void)?
    var onCloseWorkspace: ((Workspace.ID) -> Void)?
    var onRenameWorkspace: ((Workspace.ID) -> Void)?
    /// Fase 3.3 — fired when the user picks "New Group…" from a tab's
    /// context menu. Host prompts for a name and creates the group, then
    /// immediately assigns the target workspace to it.
    var onNewGroupForWorkspace: ((Workspace.ID) -> Void)?
    /// Fired by `WorkspaceTabView` when a pane header is dropped on it
    /// (Fase 2.2). Window controller orchestrates the store mutations.
    var onPaneDropped: ((_ paneID: UUID, _ source: Workspace.ID, _ destination: Workspace.ID) -> Void)?
    /// Fired when the user picks "Close N Workspaces" from the context menu
    /// with a multi-select set > 1. Window controller runs confirmation +
    /// performs each teardown. Fase 2.6.
    var onCloseMultipleWorkspaces: (([Workspace.ID]) -> Void)?

    /// Fase 2.6 — workspace IDs currently multi-selected (⌘-click / ⇧-click).
    /// Always a superset of the tabs the user intentionally added beyond the
    /// active workspace. Cleared on a plain click.
    private(set) var selectedIDs: Set<Workspace.ID> = []

    /// Selected workspace IDs in visual order. Consumers use this for bulk
    /// operations so teardown order matches what the user sees in the tab bar.
    var selectedWorkspaceIDsInVisualOrder: [Workspace.ID] {
        store.order.filter { selectedIDs.contains($0) }
    }

    // MARK: - State

    let store: WorkspaceStore
    let windowID: String

    private let stack = NSStackView()
    private var tabViews: [Workspace.ID: WorkspaceTabView] = [:]
    private let addButton = NSButton(title: String(localized: "tabs.button.new.title", comment: "Visible title on the 'new workspace' tab button — typically the literal '+' symbol."), target: nil, action: nil)
    private var workspaceObservationToken: ObservationToken?

    // MARK: - Init

    init(store: WorkspaceStore, windowID: String) {
        self.store = store
        self.windowID = windowID
        super.init(frame: .zero)
        wantsLayer = true
        // Opaque background so AppKit's `mouseDownCanMoveWindow = false`
        // override on this view (and its WorkspaceTabView children) is
        // actually honored. Transparent views in the titlebar strip let
        // AppKit's native titlebar-drag tracking win, moving the window
        // instead of letting our tab-drag handlers run.
        layer?.backgroundColor = MacTheme.surfaceBase.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        // RTL-aware: 12pt trailing padding is expressed via constraint constant instead of
        // `edgeInsets.right`, because NSEdgeInsets uses absolute left/right that do not mirror
        // under .rightToLeft layout direction.
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Propagate RTL intent to the inner stack so arrangedSubviews flow right-to-left when
        // the app's effective locale is RTL. On macOS, `NSApp.userInterfaceLayoutDirection` is
        // not auto-updated by `-AppleLanguages '(ar)'` overrides, so we detect via character
        // direction of the active language (matches the detection in WindowChromeViewController).
        let isRTL: Bool = {
            let langID = Locale.current.language.languageCode?.identifier
                ?? Locale.preferredLanguages.first
                ?? "en"
            return NSLocale.characterDirection(forLanguage: langID) == .rightToLeft
        }()
        if isRTL {
            stack.userInterfaceLayoutDirection = .rightToLeft
            userInterfaceLayoutDirection = .rightToLeft
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38),
        ])

        styleAddButton()
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = String(localized: "workspaceTabs.button.add.tooltip", comment: "Tooltip on the '+ new workspace' button in the tab strip.")
        addButton.setAccessibilityLabel(String(localized: "workspaceTabs.button.add.a11y", comment: "VoiceOver label for the '+ new workspace' button in the tab strip."))

        rebuild()
        // Fase 3.1 — ObservationTracker replaces the two NotificationCenter
        // observers. ConversationStore is NOT observed because `rebuild()`
        // does not read any conversation (handles are only rendered in the
        // sidebar). `groupID` and `orderedGroups` are also out — they are
        // only consumed by the right-click context menu, which is read fresh
        // on menu open.
        workspaceObservationToken = ObservationTracker.observe(self,
            reads: { $0.observationReads() },
            onChange: { $0.rebuild() }
        )

        // Accept both workspace-tab reorder drags and pane-header drops.
        registerForDraggedTypes([
            WorkspaceTabView.pasteboardType,
            PaneHeaderView.panePasteboardType,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Observed surface for `rebuild()`. Must touch every property the
    /// render reads; refactoring the render requires updating this too.
    private func observationReads() {
        for ws in store.orderedWorkspaces {
            _ = ws.name
            _ = ws.branch
            _ = ws.layout.leafCount
        }
        _ = store.activeWorkspaceID(in: windowID)
    }

    @objc private func addTapped(_ sender: Any?) { onAddWorkspace?() }

    /// Plain "+" text (Pencil `BXLDA`: 16pt JetBrains Mono `#555B6E`, no
    /// border, no fill). Previous iteration had a green-bordered pill which
    /// was visually loud compared to SXnc2's minimal add-workspace affordance.
    private func styleAddButton() {
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.wantsLayer = true
        addButton.layer?.backgroundColor = NSColor.clear.cgColor
        addButton.layer?.borderWidth = 0
        let attr = NSAttributedString(
            string: "+",
            attributes: [
                .font: Typography.monoNSFont(size: 16, weight: .regular),
                .foregroundColor: MacTheme.textMutedSidebar,
            ]
        )
        addButton.attributedTitle = attr
        addButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 18),
            addButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func rebuild() {
        let workspaces = store.orderedWorkspaces
        let activeID = store.activeWorkspaceID(in: windowID)
        let isOnly = workspaces.count <= 1

        // Fase 2.6 — prune selectedIDs of workspaces that no longer exist.
        selectedIDs = selectedIDs.filter { id in workspaces.contains(where: { $0.id == id }) }

        var keptIDs: Set<Workspace.ID> = []
        for (idx, ws) in workspaces.enumerated() {
            keptIDs.insert(ws.id)
            let active = (ws.id == activeID)
            let title = Self.displayTitle(for: ws)
            let count = Self.conversationCount(for: ws)
            let multiSelected = selectedIDs.contains(ws.id)
            if let existing = tabViews[ws.id] {
                existing.setActive(active)
                existing.setTitle(title)
                existing.setCount(count)
                existing.setIsOnlyWorkspace(isOnly)
                existing.setMultiSelected(multiSelected)
                if stack.arrangedSubviews.firstIndex(of: existing) != idx {
                    stack.removeArrangedSubview(existing)
                    stack.insertArrangedSubview(existing, at: idx)
                }
            } else {
                let tab = WorkspaceTabView(workspaceID: ws.id, title: title, count: count, isActive: active)
                tab.setIsOnlyWorkspace(isOnly)
                tab.setMultiSelected(multiSelected)
                tab.onClick = { [weak self] in
                    guard let self else { return }
                    // Plain click clears the multi-select set and activates
                    // (existing behaviour — preserved so single-click UX
                    // doesn't regress for users unaware of modifier keys).
                    self.selectedIDs.removeAll()
                    self.onWorkspaceActivated?(ws.id)
                }
                tab.onClickWithModifiers = { [weak self] mods in
                    self?.handleModifierClick(on: ws.id, modifiers: mods)
                }
                tab.onRequestClose = { [weak self] id in
                    self?.onCloseWorkspace?(id)
                }
                tab.onRequestContextMenu = { [weak self] id in
                    self?.contextMenu(for: id)
                }
                tab.onPaneDropped = { [weak self] paneID, source, destination in
                    self?.onPaneDropped?(paneID, source, destination)
                }
                tab.onReorderDragStarted = { [weak self] id, locationInWindow in
                    self?.handleTabReorderDrag(id: id, locationInWindow: locationInWindow, phase: .started)
                }
                tab.onReorderDragMoved = { [weak self] id, locationInWindow in
                    self?.handleTabReorderDrag(id: id, locationInWindow: locationInWindow, phase: .moved)
                }
                tab.onReorderDragEnded = { [weak self] id, locationInWindow in
                    self?.handleTabReorderDrag(id: id, locationInWindow: locationInWindow, phase: .ended)
                }
                tabViews[ws.id] = tab
                stack.insertArrangedSubview(tab, at: idx)
            }
        }
        for id in tabViews.keys where !keptIDs.contains(id) {
            if let tab = tabViews.removeValue(forKey: id) {
                stack.removeArrangedSubview(tab)
                tab.removeFromSuperview()
            }
        }
        if addButton.superview !== stack {
            stack.addArrangedSubview(addButton)
        } else if stack.arrangedSubviews.last !== addButton {
            stack.removeArrangedSubview(addButton)
            stack.addArrangedSubview(addButton)
        }
        stack.setCustomSpacing(10, after: addButton.superview === stack
            ? (stack.arrangedSubviews.last(where: { $0 !== addButton }) ?? addButton)
            : addButton)
    }

    /// `project / branch` when a branch exists, else just the workspace name.
    private static func displayTitle(for ws: Workspace) -> String {
        if let branch = ws.branch, !branch.isEmpty {
            return "\(ws.name) / \(branch)"
        }
        return ws.name
    }

    private static func conversationCount(for ws: Workspace) -> Int {
        ws.layout.leafCount
    }

    private func contextMenu(for workspaceID: Workspace.ID) -> NSMenu {
        let menu = NSMenu(title: "Workspace")
        let rename = NSMenuItem(title: String(localized: "tabs.context.renameWorkspace", comment: "Right-click menu on a workspace tab — rename the workspace."), action: #selector(renameTapped(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = workspaceID
        menu.addItem(rename)

        // Fase 3.3 — Group submenu.
        menu.addItem(groupSubmenuItem(for: workspaceID))

        menu.addItem(.separator())

        let close = NSMenuItem(title: String(localized: "tabs.context.closeWorkspace", comment: "Right-click menu on a workspace tab — close this workspace."), action: #selector(closeTapped(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = workspaceID
        close.isEnabled = store.orderedWorkspaces.count > 1
        menu.addItem(close)

        // Fase 2.6 — when a multi-select is active AND includes the tab the
        // user right-clicked, offer a "Close N Workspaces" bulk action. The
        // count excludes workspaces that would leave the window empty
        // (handled at teardown time by `SoyehtMainWindowController`).
        if selectedIDs.count > 1 && selectedIDs.contains(workspaceID) {
            let bulk = NSMenuItem(
                title: "Close \(selectedIDs.count) Workspaces",
                action: #selector(closeMultipleTapped(_:)),
                keyEquivalent: ""
            )
            bulk.target = self
            bulk.isEnabled = store.orderedWorkspaces.count > selectedIDs.count
            menu.addItem(bulk)
        }
        return menu
    }

    /// Fase 2.6 — ⌘-click toggles; ⇧-click selects a contiguous range
    /// between the anchor (active workspace) and the clicked tab in
    /// `store.order`. No modifier is handled by `onClick` above.
    private func handleModifierClick(on workspaceID: Workspace.ID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            toggleWorkspaceSelection(for: workspaceID)
            return
        }
        if modifiers.contains(.shift) {
            let order = store.order
            guard let clickedIdx = order.firstIndex(of: workspaceID) else { return }
            // Anchor: active workspace if present, else the first selected,
            // else the clicked tab itself (degenerate — range is empty).
            let anchorID = store.activeWorkspaceID(in: windowID)
                ?? selectedIDs.first
                ?? workspaceID
            guard let anchorIdx = order.firstIndex(of: anchorID) else { return }
            let lo = min(clickedIdx, anchorIdx)
            let hi = max(clickedIdx, anchorIdx)
            selectedIDs = Set(order[lo...hi])
            rebuild()
            return
        }
    }

    /// Keyboard/menu fallback for Fase 2.6. Mirrors the ⌘-click semantics:
    /// toggles membership, seeds from the active workspace when the set is
    /// empty, and collapses back to "no multi-selection" when only the
    /// active workspace would remain selected.
    func toggleWorkspaceSelection(atVisualIndex index: Int) {
        let ordered = store.order
        guard index >= 0, index < ordered.count else {
            NSSound.beep()
            return
        }
        toggleWorkspaceSelection(for: ordered[index])
    }

    private func toggleWorkspaceSelection(for workspaceID: Workspace.ID) {
        let activeID = store.activeWorkspaceID(in: windowID)
        if selectedIDs.contains(workspaceID) {
            selectedIDs.remove(workspaceID)
            if let activeID, selectedIDs == [activeID] {
                selectedIDs.removeAll()
            }
        } else {
            if selectedIDs.isEmpty, let activeID {
                selectedIDs.insert(activeID)
            }
            selectedIDs.insert(workspaceID)
        }
        rebuild()
    }

    /// Look up the workspace tab at a window-local point. Used by the
    /// titlebar mouse-drag fallback in `SoyehtMainWindowController` so it can
    /// decide whether to suppress AppKit's native window-drag and route the
    /// events to our custom reorder path instead. Returns nil if the point
    /// is not over any tab.
    func tabID(atWindowPoint point: NSPoint) -> Workspace.ID? {
        let localPoint = convert(point, from: nil)
        for workspaceID in store.order {
            guard let tab = tabViews[workspaceID] else { continue }
            let tabPoint = tab.convert(point, from: nil)
            if tab.clickRegion(at: tabPoint) == .body {
                _ = localPoint
                return workspaceID
            }
        }
        return nil
    }

    /// Drag reorder entry point for the titlebar mouse-drag fallback.
    /// Accepts a window-local point; performs live reorder + lifted state.
    func handleReorderDrag(draggedID: Workspace.ID, atWindowPoint point: NSPoint, phase: LocalTabDragPhase) {
        handleTabReorderDrag(id: draggedID, locationInWindow: point, phase: phase)
    }

    @discardableResult
    func handleFallbackClick(atWindowPoint point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        let localPoint = convert(point, from: nil)
        let relevant: NSEvent.ModifierFlags = [.command, .shift]

        if convert(addButton.bounds, from: addButton).contains(localPoint) {
            onAddWorkspace?()
            return true
        }

        for workspaceID in store.order {
            guard let tab = tabViews[workspaceID] else { continue }
            let tabPoint = tab.convert(point, from: nil)
            guard let region = tab.clickRegion(at: tabPoint) else { continue }
            switch region {
            case .closeButton:
                onCloseWorkspace?(workspaceID)
            case .body:
                if !modifiers.intersection(relevant).isEmpty {
                    handleModifierClick(on: workspaceID, modifiers: modifiers)
                } else {
                    selectedIDs.removeAll()
                    onWorkspaceActivated?(workspaceID)
                }
            }
            return true
        }

        return false
    }

    @objc private func renameTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Workspace.ID else { return }
        onRenameWorkspace?(id)
    }

    @objc private func closeTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Workspace.ID else { return }
        onCloseWorkspace?(id)
    }

    @objc private func closeMultipleTapped(_ sender: NSMenuItem) {
        let ids = store.order.filter { selectedIDs.contains($0) }  // preserve visual order
        guard ids.count > 1 else { return }
        selectedIDs.removeAll()
        onCloseMultipleWorkspaces?(ids)
    }

    // MARK: - Group submenu (Fase 3.3)

    /// Build a "Group ▸" submenu listing each existing group as a toggle,
    /// an "Ungroup" option when the workspace is already grouped, and a
    /// "New Group…" entry to create+assign in one shot.
    private func groupSubmenuItem(for workspaceID: Workspace.ID) -> NSMenuItem {
        let header = NSMenuItem(title: String(localized: "tabs.context.group.header", comment: "Submenu header in the tab context menu that reveals group-assignment options."), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Group")

        let currentGroupID = store.workspace(workspaceID)?.groupID

        // "None" row — unassigns.
        let none = NSMenuItem(
            title: String(localized: "tabs.context.group.none", comment: "Submenu item that removes the workspace from any group."),
            action: #selector(assignToGroupTapped(_:)),
            keyEquivalent: ""
        )
        none.target = self
        none.representedObject = GroupAssignmentPayload(workspaceID: workspaceID, groupID: nil)
        none.state = currentGroupID == nil ? .on : .off
        submenu.addItem(none)

        if !store.orderedGroups.isEmpty {
            submenu.addItem(.separator())
            for group in store.orderedGroups {
                let item = NSMenuItem(
                    title: group.name,
                    action: #selector(assignToGroupTapped(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = GroupAssignmentPayload(workspaceID: workspaceID, groupID: group.id)
                item.state = (currentGroupID == group.id) ? .on : .off
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let newGroup = NSMenuItem(
            title: "New Group…",
            action: #selector(newGroupTapped(_:)),
            keyEquivalent: ""
        )
        newGroup.target = self
        newGroup.representedObject = workspaceID
        submenu.addItem(newGroup)

        header.submenu = submenu
        return header
    }

    @objc private func assignToGroupTapped(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? GroupAssignmentPayload else { return }
        store.setGroup(for: payload.workspaceID, to: payload.groupID)
    }

    @objc private func newGroupTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Workspace.ID else { return }
        onNewGroupForWorkspace?(id)
    }

    /// Value type passed via `NSMenuItem.representedObject` for group
    /// assignment rows. Using a dedicated struct avoids the tagged-tuple
    /// gymnastics that ObjC-flavored APIs otherwise require.
    private struct GroupAssignmentPayload {
        let workspaceID: Workspace.ID
        let groupID: Group.ID?
    }

    enum LocalTabDragPhase {
        case started
        case moved
        case ended
    }

    // MARK: - Drop target (Fase 2.1)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let location = convert(sender.draggingLocation, from: nil)
        if let draggedID = reorderPayload(from: sender) {
            guard let targetIndex = dropIndex(for: location, draggedID: draggedID) else {
                return false
            }
            store.reorder(draggedID, to: targetIndex)
            return true
        }
        guard let payload = panePayload(from: sender),
              let destination = workspaceID(at: location),
              payload.workspaceID != destination else { return false }
        onPaneDropped?(payload.paneID, payload.workspaceID, destination)
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsReorderDrag(sender) {
            return reorderPayload(from: sender).flatMap { dropIndex(for: convert(sender.draggingLocation, from: nil), draggedID: $0) } != nil
                ? .move
                : []
        }
        let location = convert(sender.draggingLocation, from: nil)
        guard let payload = panePayload(from: sender),
              let destination = workspaceID(at: location),
              payload.workspaceID != destination else { return [] }
        return .move
    }

    private func acceptsReorderDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(WorkspaceTabView.pasteboardType) == true
    }

    private func reorderPayload(from sender: NSDraggingInfo) -> Workspace.ID? {
        guard let string = sender.draggingPasteboard.string(forType: WorkspaceTabView.pasteboardType),
              let uuid = UUID(uuidString: string) else { return nil }
        return uuid
    }

    private func panePayload(from sender: NSDraggingInfo) -> (paneID: UUID, workspaceID: UUID)? {
        guard let string = sender.draggingPasteboard.string(forType: PaneHeaderView.panePasteboardType) else {
            return nil
        }
        return PaneHeaderView.decodePanePayload(string)
    }

    private func workspaceID(at point: NSPoint) -> Workspace.ID? {
        for ws in store.orderedWorkspaces {
            guard let tab = tabViews[ws.id] else { continue }
            let tabFrame = convert(tab.bounds, from: tab)
            if tabFrame.contains(point) {
                return ws.id
            }
        }
        return nil
    }

    /// Captures all mutable state for an in-flight tab drag. Exists only
    /// between `.started` and `.ended`. Matches the flow shown in Pencil
    /// reference `s5y0b` (Tab Drag Reordering States).
    private struct TabDragState {
        let draggedID: Workspace.ID
        /// Snapshot of `store.order.firstIndex(of: draggedID)` at start.
        let sourceIndex: Int
        /// Cursor in WorkspaceTabsView-local coords at `.started`.
        let startCursor: NSPoint
        /// Snapshot of every tab's frame at start. Used to compute shifts
        /// and the dragged tab's visual center while the cursor moves.
        let originalFrames: [Workspace.ID: CGRect]
        /// Width of the dragged tab + stack spacing — the exact amount
        /// each shifted tab should translate to make room.
        let shiftAmount: CGFloat
        /// The index the dragged tab would land at if released right now.
        /// Updated by `updateTabDrag` as the cursor crosses midpoints.
        var currentTargetIndex: Int
    }

    private var tabDragState: TabDragState?

    private func handleTabReorderDrag(id: Workspace.ID, locationInWindow: NSPoint, phase: LocalTabDragPhase) {
        let location = convert(locationInWindow, from: nil)
        switch phase {
        case .started:
            tabDragState = beginTabDrag(draggedID: id, cursor: location)
        case .moved:
            guard var state = tabDragState else { return }
            updateTabDrag(state: &state, cursor: location)
            tabDragState = state
        case .ended:
            guard var state = tabDragState else { return }
            tabDragState = nil
            // Sync state with the final cursor position before committing.
            // Automation/synthetic drag sources emit sparse `.moved` events
            // and the last sample is often well before `.ended`, so the
            // target index would be stale. Real mouse drags fire events
            // continuously so this is a no-op for them.
            updateTabDrag(state: &state, cursor: location)
            finishTabDrag(state: state)
        }
    }

    private func beginTabDrag(draggedID: Workspace.ID, cursor: NSPoint) -> TabDragState? {
        let order = store.order
        guard let sourceIdx = order.firstIndex(of: draggedID),
              let draggedTab = tabViews[draggedID] else { return nil }
        var frames: [Workspace.ID: CGRect] = [:]
        for id in order {
            if let tab = tabViews[id] { frames[id] = tab.frame }
        }
        draggedTab.setDragLifted(true)
        return TabDragState(
            draggedID: draggedID,
            sourceIndex: sourceIdx,
            startCursor: cursor,
            originalFrames: frames,
            shiftAmount: draggedTab.frame.width + max(stack.spacing, 0),
            currentTargetIndex: sourceIdx
        )
    }

    private func updateTabDrag(state: inout TabDragState, cursor: NSPoint) {
        guard let draggedTab = tabViews[state.draggedID],
              let origFrame = state.originalFrames[state.draggedID] else { return }

        // 1. Dragged tab follows the cursor — 1:1, no animation (would lag).
        let dx = cursor.x - state.startCursor.x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draggedTab.layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: 0))
        CATransaction.commit()

        // 2. Target index is the slot whose midpoint the dragged tab's
        // visual center has crossed. Using `originalFrames` (not current
        // frames) keeps the math stable as we animate siblings with
        // transforms — their model frames never actually move.
        let draggedCenterX = origFrame.midX + dx
        let order = store.order
        var newTarget = state.sourceIndex
        for (i, id) in order.enumerated() where id != state.draggedID {
            guard let f = state.originalFrames[id] else { continue }
            if draggedCenterX < f.midX {
                newTarget = i <= state.sourceIndex ? i : i - 1
                break
            }
            newTarget = i <= state.sourceIndex ? i + 1 : i
        }
        newTarget = max(0, min(order.count - 1, newTarget))

        guard newTarget != state.currentTargetIndex else { return }
        state.currentTargetIndex = newTarget
        animateSiblingShifts(for: state)
    }

    /// Slide the non-dragged tabs into the positions they would occupy if
    /// the drop were committed right now. Uses layer transforms so the
    /// `frame`/constraint model stays untouched — the store isn't mutated,
    /// and the stack view never sees a layout change. This is what kills
    /// the "flickering colors" from the previous implementation, which
    /// called `store.reorder` on every mouseDragged and triggered a full
    /// rebuild per event.
    private func animateSiblingShifts(for state: TabDragState) {
        let order = store.order
        let source = state.sourceIndex
        let target = state.currentTargetIndex
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            for (i, id) in order.enumerated() where id != state.draggedID {
                guard let tab = tabViews[id] else { continue }
                let shift: CGFloat
                if source < target {
                    shift = (i > source && i <= target) ? -state.shiftAmount : 0
                } else if source > target {
                    shift = (i >= target && i < source) ? state.shiftAmount : 0
                } else {
                    shift = 0
                }
                tab.animator().layer?.setAffineTransform(
                    CGAffineTransform(translationX: shift, y: 0)
                )
            }
        }
    }

    /// Final phase: clear all visual transforms, drop the lifted state,
    /// and commit the single reorder. The rebuild triggered by the store
    /// leaves every tab at its post-reorder frame, which is exactly where
    /// we already had it via transforms — so dropping the transforms is
    /// a no-op visually for non-dragged tabs, and a small snap-to-slot
    /// for the dragged tab (since the cursor rarely releases right over
    /// the target slot's midpoint).
    private func finishTabDrag(state: TabDragState) {
        let draggedTab = tabViews[state.draggedID]
        draggedTab?.setDragLifted(false)

        // Clear non-dragged siblings immediately — their post-rebuild frames
        // match the visual positions we had them at, so there's no jump.
        for (id, tab) in tabViews where id != state.draggedID {
            tab.layer?.setAffineTransform(.identity)
        }

        // Commit reorder (triggers `rebuild`, which moves the dragged tab
        // into its new arrangedSubview index and gives it a new frame).
        if state.currentTargetIndex != state.sourceIndex {
            store.reorder(state.draggedID, to: state.currentTargetIndex)
        }

        // Compute the translation needed to keep the dragged tab visually
        // where the user released it, then animate to identity so it
        // smoothly glides into its new slot.
        if let draggedTab,
           let origFrame = state.originalFrames[state.draggedID] {
            let preRebuildVisualX = origFrame.origin.x + (draggedTab.layer?.affineTransform().tx ?? 0)
            let newFrame = draggedTab.frame
            let snapFromX = preRebuildVisualX - newFrame.origin.x
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            draggedTab.layer?.setAffineTransform(CGAffineTransform(translationX: snapFromX, y: 0))
            CATransaction.commit()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                draggedTab.animator().layer?.setAffineTransform(.identity)
            }
        }
    }

    /// Translate a drop `point` (self coordinate space) into a target
    /// `order` index. Uses each tab's midX as the insertion boundary —
    /// dropping in the left half of a tab inserts before it, right half
    /// inserts after. Points past the last tab append. The value we
    /// return assumes the dragged tab is **still** present in `order`; the
    /// store's reorder call handles the actual removal+insert with the same
    /// invariant (`insert after remove`, clamped).
    private func dropIndex(for point: NSPoint, draggedID: Workspace.ID) -> Int? {
        let workspaces = store.orderedWorkspaces
        guard !workspaces.isEmpty else { return 0 }
        for (idx, ws) in workspaces.enumerated() {
            guard let tab = tabViews[ws.id] else { continue }
            let tabFrame = convert(tab.bounds, from: tab)
            if tabFrame.contains(point) {
                return point.x < tabFrame.midX ? idx : idx + 1
            }
        }
        guard let lastID = workspaces.last?.id,
              let lastTab = tabViews[lastID]
        else { return nil }
        let lastFrame = convert(lastTab.bounds, from: lastTab)
        let addFrame = convert(addButton.bounds, from: addButton)
        let validAppendZone = CGRect(
            x: lastFrame.maxX,
            y: min(lastFrame.minY, addFrame.minY),
            width: max(0, addFrame.minX - lastFrame.maxX),
            height: max(lastFrame.maxY, addFrame.maxY) - min(lastFrame.minY, addFrame.minY)
        )
        if validAppendZone.contains(point) {
            return workspaces.count
        }
        return nil
    }
}
