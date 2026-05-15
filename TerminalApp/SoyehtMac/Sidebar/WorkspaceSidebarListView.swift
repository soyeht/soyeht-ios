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
    var onPaneMoved: ((_ paneID: Conversation.ID, _ sourceWorkspaceID: Workspace.ID, _ destinationWorkspaceID: Workspace.ID) -> Void)?

    // MARK: - State dependencies

    private let workspaceStore: WorkspaceStore
    private let conversationStore: ConversationStore
    private let windowID: String
    /// Closure so the view stays decoupled from `SoyehtMainWindowController`;
    /// it just asks "which workspace does this window consider active?"
    private let activeWorkspaceIDProvider: () -> Workspace.ID?

    // MARK: - Subviews

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: String(localized: "sidebar.header.label", comment: "Sticky header text at the top of the workspaces sidebar — monospace code-comment style. Many languages keep the literal '// workspaces' to preserve the visual style."))
    private let searchIcon = NSImageView()
    private let closeButton = NSButton()

    private let scroll = NSScrollView()
    private let body = NSStackView()
    private var groups: [Workspace.ID: WorkspaceGroupView] = [:]

    /// Fase 3.1 — observation loop tokens. One per store because each tracker
    /// reads from a different `@Observable` root. PairingPresenceServer is
    /// not `@Observable`, so that observer stays on NotificationCenter.
    private var workspaceObservationToken: ObservationToken?
    private var conversationObservationToken: ObservationToken?

    // MARK: - Init

    init(
        workspaceStore: WorkspaceStore,
        conversationStore: ConversationStore,
        windowID: String,
        activeWorkspaceIDProvider: @escaping () -> Workspace.ID?
    ) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        self.windowID = windowID
        self.activeWorkspaceIDProvider = activeWorkspaceIDProvider
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        reload()

        // Fase 3.1 — ObservationTracker for WorkspaceStore + ConversationStore.
        // Granularity note: `conversations(in:)` and `workspace(_:)` both register
        // on the whole backing dictionaries, so any rename/add/remove anywhere
        // invalidates — same semantics as before. The refactor gain here is
        // code clarity, not per-property invalidation.
        workspaceObservationToken = ObservationTracker.observe(self,
            reads: { $0.workspaceObservationReads() },
            onChange: { $0.reload() }
        )
        conversationObservationToken = ObservationTracker.observe(self,
            reads: { $0.conversationObservationReads() },
            onChange: { $0.reload() }
        )
        // PairingPresenceServer is not @Observable, so this observer stays
        // on NotificationCenter.
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: PairingPresenceServer.membershipDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Observed surface for `reload()` — workspace side. Mirrors every read
    /// path executed by `reload()` and `buildRows(for:)`. Refactoring either
    /// requires updating this too.
    private func workspaceObservationReads() {
        _ = workspaceStore.workspaceOrder(in: windowID)
        for ws in workspaceStore.orderedWorkspaces(in: windowID) {
            _ = ws.name
            _ = ws.kind
            _ = ws.layout.leafCount
            _ = ws.layout.leafIDs
            _ = ws.activePaneID
        }
    }

    /// Observed surface for `reload()` — conversation side. Reads the
    /// conversations in each workspace (for the row handles). Registers
    /// observation on the whole `conversations` dict of ConversationStore.
    private func conversationObservationReads() {
        _ = workspaceStore.workspaceOrder(in: windowID)
        for ws in workspaceStore.orderedWorkspaces(in: windowID) {
            _ = conversationStore.conversations(in: ws.id)
        }
    }

    // MARK: - Build

    private func build() {
        // Header (sticky pseudo-sticky — actually fixed at top since the
        // content scrolls beneath it).
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MacTypography.NSFonts.sidebarHeader
        titleLabel.textColor = SidebarTokens.sectionLabel
        header.addSubview(titleLabel)

        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = tintedSymbol("magnifyingglass", tint: SidebarTokens.sectionLabel)
        // Render the SF Symbol at its native size — NSImageView's default
        // `.scaleProportionallyDown` would distort the glyph inside the 12×12
        // frame.
        searchIcon.imageScaling = .scaleNone
        header.addSubview(searchIcon)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.image = tintedSymbol("xmark", tint: SidebarTokens.sectionLabel)
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleNone
        closeButton.target = self
        closeButton.action = #selector(dismissTapped)
        closeButton.setAccessibilityLabel(String(localized: "sidebar.button.close.a11y", comment: "VoiceOver label for the × button that closes the sidebar overlay."))
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
        let cfg = NSImage.SymbolConfiguration(pointSize: Typography.iconNavPointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return img.withSymbolConfiguration(cfg)
    }

    // MARK: - Reload

    @objc private func storeChanged() { reload() }

    func reload() {
        let workspaces = workspaceStore.orderedWorkspaces(in: windowID)
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
                group.onPaneDropped = { [weak self] paneID, source, destination in
                    self?.onPaneMoved?(paneID, source, destination)
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
                workspaceID: ws.id,
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
