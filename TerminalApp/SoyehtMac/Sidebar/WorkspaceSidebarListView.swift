import AppKit
import SoyehtCore

/// Scrollable list of workspace groups, headed by the sticky
/// `// workspaces` label + search/close icons (Pencil `nOiJG`).
/// Owned by `FloatingSidebarViewController`.
@MainActor
final class WorkspaceSidebarListView: NSView {

    // MARK: - Callbacks

    var onDismiss: (() -> Void)?
    var onConversationSelected: ((Workspace.ID, Conversation.ID) -> Void)?

    // MARK: - State dependencies

    private let workspaceStore: WorkspaceStore
    private let conversationStore: ConversationStore
    /// Closure so the view stays decoupled from `SoyehtMainWindowController`;
    /// it just asks "which workspace does this window consider active?"
    private let activeWorkspaceIDProvider: () -> Workspace.ID?

    // MARK: - Subviews

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "// workspaces")
    private let searchIcon = NSImageView()
    private let closeButton = NSButton()

    private let scroll = NSScrollView()
    private let body = NSStackView()
    private var groups: [Workspace.ID: WorkspaceGroupView] = [:]

    // MARK: - Init

    init(
        workspaceStore: WorkspaceStore,
        conversationStore: ConversationStore,
        activeWorkspaceIDProvider: @escaping () -> Workspace.ID?
    ) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        self.activeWorkspaceIDProvider = activeWorkspaceIDProvider
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        reload()

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: WorkspaceStore.changedNotification, object: workspaceStore
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: ConversationStore.changedNotification, object: conversationStore
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: PairingPresenceServer.membershipDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Build

    private func build() {
        // Header (sticky pseudo-sticky — actually fixed at top since the
        // content scrolls beneath it).
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Typography.monoNSFont(size: 11, weight: .medium)
        titleLabel.textColor = SidebarTokens.sectionLabel
        header.addSubview(titleLabel)

        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = tintedSymbol("magnifyingglass", tint: SidebarTokens.sectionLabel)
        header.addSubview(searchIcon)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.image = tintedSymbol("xmark", tint: SidebarTokens.sectionLabel)
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(dismissTapped)
        closeButton.setAccessibilityLabel("Close Sidebar")
        header.addSubview(closeButton)

        // Scrollable body
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)

        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            searchIcon.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            searchIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 12),
            searchIcon.heightAnchor.constraint(equalToConstant: 12),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            body.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])
    }

    private func tintedSymbol(_ name: String, tint: NSColor) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return img.withSymbolConfiguration(cfg)
    }

    // MARK: - Reload

    @objc private func storeChanged() { reload() }

    func reload() {
        let workspaces = workspaceStore.orderedWorkspaces
        let activeID = activeWorkspaceIDProvider()
        var keptIDs: Set<Workspace.ID> = []

        for (idx, ws) in workspaces.enumerated() {
            keptIDs.insert(ws.id)
            let rows = buildRows(for: ws)
            let gm = WorkspaceGroupView.Model(
                workspaceID: ws.id,
                name: ws.name,
                kind: ws.kind,
                count: ws.layout.leafCount,
                isWorkspaceActive: ws.id == activeID,
                rows: rows
            )
            if let existing = groups[ws.id] {
                existing.update(gm)
                if body.arrangedSubviews.firstIndex(of: existing) != idx {
                    body.removeArrangedSubview(existing)
                    body.insertArrangedSubview(existing, at: idx)
                }
            } else {
                let group = WorkspaceGroupView(model: gm)
                group.onRowClick = { [weak self] wsID, convID in
                    self?.onConversationSelected?(wsID, convID)
                }
                groups[ws.id] = group
                body.insertArrangedSubview(group, at: idx)
                group.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
        }
        for id in groups.keys where !keptIDs.contains(id) {
            if let g = groups.removeValue(forKey: id) {
                body.removeArrangedSubview(g)
                g.removeFromSuperview()
            }
            SidebarCollapseStore.forget(id)
        }
    }

    private func buildRows(for ws: Workspace) -> [WorkspaceGroupView.RowModel] {
        let isWorkspaceActive = ws.id == activeWorkspaceIDProvider()
        // Map conversation by id for quick lookup — we want to iterate
        // layout leaves (the user's source of truth for "what panes exist")
        // and pull conversation handles where they've been hydrated.
        // Panes created as empty placeholders (pickingAgent state) have a
        // leaf id in the tree but no Conversation persisted yet; they still
        // deserve a row so the count + row set stay in sync.
        let convsByID = Dictionary(
            uniqueKeysWithValues: conversationStore.conversations(in: ws.id).map { ($0.id, $0) }
        )
        return ws.layout.leafIDs.map { leafID in
            let handle = convsByID[leafID]?.handle ?? "—"
            let isFocused = ws.activePaneID == leafID
            let isSelected = isFocused && isWorkspaceActive
            let iphone = !PairingPresenceServer.shared
                .attachedDevices(forPane: leafID.uuidString).isEmpty
            return WorkspaceGroupView.RowModel(row: .init(
                conversationID: leafID,
                handle: handle,
                isFocusedPane: isFocused,
                isSelected: isSelected,
                hasIPhoneAttached: iphone
            ))
        }
    }

    @objc private func dismissTapped() { onDismiss?() }
}

/// A flipped NSView so content inside an NSScrollView flows top-down
/// naturally (NSView defaults to bottom-up origins).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
