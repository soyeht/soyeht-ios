import AppKit
import Foundation
import SoyehtCore
import SwiftTerm

@MainActor
final class EditorPaneViewController: NSViewController, PaneContentViewControlling, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    let paneID: Conversation.ID
    let contentKind: PaneContentKind = .editor
    private(set) var state: EditorPaneState
    var headerAccessories: PaneHeaderAccessories { .specialDefault }
    var matchingKey: String { PaneContent.editor(state).matchingKey }
    var headerTitle: String {
        state.selectedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? URL(fileURLWithPath: state.rootPath).lastPathComponent
    }
    var headerSubtitle: String? { "editor" }

    private let rootNode: EditorFileNode
    private var rootURL: URL {
        URL(fileURLWithPath: state.rootPath, isDirectory: true).standardizedFileURL
    }
    private let outlineView = NSOutlineView()
    private let textView = EditorTextView()
    private let tabBar = EditorTabBarView()
    private let breadcrumbBar = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLeftLabel = NSTextField(labelWithString: "")
    private let footerRightLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private var sidebarContainer: NSStackView?
    private var explorerHeader: NSStackView?
    private var projectDisclosureButton: NSButton?
    private var fileTreeScroll: NSScrollView?
    private var editorAreaContainer: NSStackView?
    private var textViewScroll: NSScrollView?
    private var footerView: NSStackView?
    private weak var splitView: NSSplitView?
    private var sidebarWidthPreferenceConstraint: NSLayoutConstraint?
    private var didApplyInitialSidebarWidth = false
    private var didScheduleInitialSidebarWidth = false
    private var applyingProgrammaticSidebarWidth = false
    private var scrollIndicator: TerminalScrollIndicatorView?
    private var sidebarScrollIndicator: TerminalScrollIndicatorView?
    private static let sidebarExpandedWidth: CGFloat = 240
    private static let sidebarMaxWidth: CGFloat = 420
    private static let scrollIndicatorWidth: CGFloat = 15
    private var loadedDocument: EditorLoadedDocument?
    private var isDirty = false
    private var externalChangePending = false
    private var suppressFileEventsUntil: Date?
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: CInt = -1
    private var directoryWatcher: EditorDirectoryWatcher?
    private var fileTreeRefreshWorkItem: DispatchWorkItem?
    private var isProjectExpanded: Bool

    init(paneID: Conversation.ID, state: EditorPaneState) {
        self.paneID = paneID
        let normalizedState = Self.normalized(state)
        self.state = normalizedState
        self.isProjectExpanded = normalizedState.isProjectExpanded
        let rootURL = URL(fileURLWithPath: normalizedState.rootPath, isDirectory: true).standardizedFileURL
        self.rootNode = EditorFileNode(url: rootURL, isDirectory: true)
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: .preferencesDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        fileTreeRefreshWorkItem?.cancel()
        directoryWatcher?.stop()
        watcher?.cancel()
        watcher = nil
        watcherFD = -1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private static func normalized(_ state: EditorPaneState) -> EditorPaneState {
        var normalized = state
        normalized.rootPath = canonicalPath(state.rootPath, isDirectory: true)
        normalized.selectedFilePath = state.selectedFilePath.map { canonicalPath($0, isDirectory: false) }

        var seen = Set<String>()
        normalized.openFilePaths = state.openFilePaths
            .map { canonicalPath($0, isDirectory: false) }
            .filter { seen.insert($0).inserted }
        return normalized
    }

    private static func canonicalPath(_ path: String, isDirectory: Bool) -> String {
        URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL.path
    }

    override func loadView() {
        let root = ArrowCursorView()
        root.wantsLayer = true
        root.layer?.backgroundColor = EditorPaneDesign.surface.cgColor

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = makeSidebar()
        let editorArea = makeEditorArea()
        sidebar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        editorArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(editorArea)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        let sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarExpandedWidth)
        sidebarWidth.priority = .defaultLow
        sidebarWidth.isActive = true
        sidebarWidthPreferenceConstraint = sidebarWidth
        splitView = split

        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        wireEditorTextViewHandlers()
        applyTheme()
        // Attach the shell's `TerminalScrollIndicatorView` pill to both
        // scrolls via the shared `MacScroll` helper. The previous attempt
        // at this (commit `a72f7a0`) used a wrapper view + addFloatingSubview
        // and failed; the helper's approach is sibling-overlay + Auto
        // Layout, same as the shell does.
        if let textViewScroll { MacScroll.attachVerticalIndicator(to: textViewScroll) }
        if let fileTreeScroll { MacScroll.attachVerticalIndicator(to: fileTreeScroll) }
        outlineView.reloadData()
        if isProjectExpanded {
            outlineView.expandItem(rootNode)
        }
        startWatchingDirectory()
        renderTabs()
        renderBreadcrumb()
        if let selected = state.selectedFilePath {
            openFile(URL(fileURLWithPath: selected), line: state.selectedLine, userInitiated: false)
        } else {
            statusLabel.stringValue = "Select a file"
            updateFooter()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleInitialSidebarWidthIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleInitialSidebarWidthIfNeeded()
    }

    private func scheduleInitialSidebarWidthIfNeeded() {
        guard !didApplyInitialSidebarWidth,
              !didScheduleInitialSidebarWidth,
              splitView != nil else { return }
        didScheduleInitialSidebarWidth = true

        let delays: [TimeInterval] = [0, 0.05, 0.15]
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyInitialSidebarWidth(finalPass: index == delays.count - 1)
            }
        }
    }

    private func applyInitialSidebarWidth(finalPass: Bool) {
        guard !didApplyInitialSidebarWidth,
              let splitView,
              splitView.arrangedSubviews.count > 1,
              splitView.bounds.width > Self.sidebarExpandedWidth else {
            if finalPass {
                didScheduleInitialSidebarWidth = false
            }
            return
        }
        setSidebarWidth(Self.sidebarExpandedWidth, animated: false)
        if finalPass {
            didApplyInitialSidebarWidth = true
            didScheduleInitialSidebarWidth = false
        }
    }

    func focusContent() {
        view.window?.makeFirstResponder(textView)
    }

    func applyTheme() {
        // Root surfaces
        view.layer?.backgroundColor = EditorPaneDesign.surface.cgColor
        editorAreaContainer?.layer?.backgroundColor = EditorPaneDesign.surface.cgColor

        // Sidebar surfaces (chrome elevation)
        sidebarContainer?.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        explorerHeader?.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        updateProjectDisclosureButton()
        fileTreeScroll?.backgroundColor = EditorPaneDesign.chrome
        outlineView.backgroundColor = EditorPaneDesign.chrome

        // Top + bottom chrome
        tabBar.applyTheme()
        breadcrumbBar.layer?.backgroundColor = EditorPaneDesign.surface.cgColor
        footerView?.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor

        // Text view
        textView.backgroundColor = EditorPaneDesign.surface
        textView.textColor = EditorPaneDesign.text
        textView.insertionPointColor = EditorPaneDesign.text
        textView.font = Self.editorBodyFont()
        textView.selectedTextAttributes = [
            .backgroundColor: EditorPaneDesign.selected,
            .foregroundColor: EditorPaneDesign.text,
        ]
        textViewScroll?.backgroundColor = EditorPaneDesign.surface

        // Status / footer labels
        statusLabel.textColor = EditorPaneDesign.muted
        footerLeftLabel.textColor = EditorPaneDesign.muted
        footerRightLabel.textColor = EditorPaneDesign.muted

        // Rebuild inner views that bake colors into per-row layers
        renderTabs()
        renderBreadcrumb()
        outlineView.reloadData()
        outlineView.expandItem(rootNode)
        applyBasicHighlighting()
        updateScrollIndicator()
        updateSidebarScrollIndicator()

        // Line number ruler tracks the body font size + repaints with the
        // new surfaceDeep / dim tokens.
        if let ruler = textViewScroll?.verticalRulerView as? EditorLineNumberRulerView {
            ruler.applyMetrics(bodySize: TerminalPreferences.shared.fontSize)
        }
        textViewScroll?.verticalRulerView?.needsDisplay = true
    }

    @objc private func preferencesDidChange() {
        applyTheme()
    }


    @objc private func clipViewBoundsDidChange() {
        updateScrollIndicator()
    }

    @objc private func sidebarClipViewBoundsDidChange() {
        updateSidebarScrollIndicator()
    }

    private func updateSidebarScrollIndicator() {
        guard let scroll = fileTreeScroll,
              let indicator = sidebarScrollIndicator,
              let doc = scroll.documentView else { return }
        let visibleHeight = scroll.contentView.bounds.height
        let totalHeight = doc.frame.height
        guard totalHeight > 0 else {
            indicator.isScrollable = false
            return
        }
        let canScroll = totalHeight > visibleHeight + 0.5
        indicator.isScrollable = canScroll
        guard canScroll else { return }
        let maxScroll = totalHeight - visibleHeight
        let clipY = scroll.contentView.bounds.origin.y
        let position = max(0, min(1, Double(clipY / maxScroll)))
        indicator.position = position
        indicator.thumbProportion = max(0.04, min(1, visibleHeight / totalHeight))
    }

    private func scrollSidebar(toIndicatorPosition position: Double) {
        guard let scroll = fileTreeScroll,
              let doc = scroll.documentView else { return }
        let visibleHeight = scroll.contentView.bounds.height
        let totalHeight = doc.frame.height
        let maxScroll = max(0, totalHeight - visibleHeight)
        let clipY = CGFloat(position) * maxScroll
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: clipY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Recompute the scroll indicator's position + thumb proportion from
    /// the current clipView bounds. Called on every scroll, plus after
    /// opening a file / changing theme.
    private func updateScrollIndicator() {
        guard let scroll = textViewScroll,
              let indicator = scrollIndicator,
              let doc = scroll.documentView else { return }
        let visibleHeight = scroll.contentView.bounds.height
        let totalHeight = doc.frame.height
        guard totalHeight > 0 else {
            indicator.isScrollable = false
            return
        }
        let canScroll = totalHeight > visibleHeight + 0.5
        indicator.isScrollable = canScroll
        guard canScroll else { return }
        let maxScroll = totalHeight - visibleHeight
        let clipY = scroll.contentView.bounds.origin.y
        // TerminalScrollIndicatorView uses non-flipped NSView coords
        // (y=0 is the bottom). It maps position=0 → thumb at top of track
        // and position=1 → thumb at bottom of track. For an editor on a
        // flipped NSScrollView, clipY=0 means "at top of file" — that's
        // where the user wants the thumb to be at TOP, i.e., position=0.
        // So position scales linearly with clipY without any inversion.
        let position = max(0, min(1, Double(clipY / maxScroll)))
        indicator.position = position
        indicator.thumbProportion = max(0.04, min(1, visibleHeight / totalHeight))
    }

    private func scrollEditor(toIndicatorPosition position: Double) {
        guard let scroll = textViewScroll,
              let doc = scroll.documentView else { return }
        let visibleHeight = scroll.contentView.bounds.height
        let totalHeight = doc.frame.height
        let maxScroll = max(0, totalHeight - visibleHeight)
        let clipY = CGFloat(position) * maxScroll
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: clipY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Font for the editor body. Reads from `TerminalPreferences.fontSize`
    /// so the editor matches the user's chosen scale (Preferences → Font Size,
    /// same source the terminal panes use).
    static func editorBodyFont() -> NSFont {
        NSFont.monospacedSystemFont(
            ofSize: TerminalPreferences.shared.fontSize,
            weight: .regular
        )
    }

    fileprivate func toggleSidebar() {
        guard let splitView,
              splitView.arrangedSubviews.count > 1 else { return }
        let currentWidth = splitView.arrangedSubviews[0].frame.width
        let target: CGFloat = currentWidth > 1 ? 0 : Self.sidebarExpandedWidth
        setSidebarWidth(target, animated: true)
    }

    private func setSidebarWidth(_ width: CGFloat, animated: Bool) {
        guard let splitView,
              splitView.arrangedSubviews.count > 1 else { return }
        sidebarWidthPreferenceConstraint?.constant = width
        applyingProgrammaticSidebarWidth = true

        guard animated else {
            splitView.setPosition(width, ofDividerAt: 0)
            applyingProgrammaticSidebarWidth = false
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            splitView.animator().setPosition(width, ofDividerAt: 0)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyingProgrammaticSidebarWidth = false
            }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        0
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, Self.sidebarMaxWidth)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingProgrammaticSidebarWidth,
              let splitView = notification.object as? NSSplitView,
              splitView === self.splitView,
              let sidebar = splitView.arrangedSubviews.first else { return }
        if sidebar.frame.width > Self.sidebarMaxWidth {
            let preferredWidth = sidebarWidthPreferenceConstraint?.constant ?? Self.sidebarExpandedWidth
            setSidebarWidth(min(max(preferredWidth, 0), Self.sidebarMaxWidth), animated: false)
            return
        }
        sidebarWidthPreferenceConstraint?.constant = sidebar.frame.width
    }

    func updateContent(_ content: PaneContent) {
        guard case .editor(let newState) = content else { return }
        let normalizedState = Self.normalized(newState)
        let previousFile = state.selectedFilePath
        if let selected = normalizedState.selectedFilePath,
           selected != previousFile {
            openFile(URL(fileURLWithPath: selected), line: normalizedState.selectedLine, userInitiated: false)
            return
        }
        state = normalizedState
        renderTabs()
        renderBreadcrumb()
        if let line = normalizedState.selectedLine {
            scrollToLine(line)
        }
    }

    func prepareForClose() {
        fileTreeRefreshWorkItem?.cancel()
        directoryWatcher?.stop()
        directoryWatcher = nil
        stopWatchingFile()
    }

    private func makeSidebar() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 0
        container.wantsLayer = true
        container.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        sidebarContainer = container

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 16)
        header.wantsLayer = true
        header.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        explorerHeader = header
        let explorerHeader = header

        let title = label("EXPLORER", size: 11, color: EditorPaneDesign.muted, weight: .regular)
        title.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let addFile = iconButton("plus", action: #selector(newFileTapped))
        addFile.toolTip = "New File"
        addFile.setAccessibilityLabel("New File")
        explorerHeader.addArrangedSubview(title)
        explorerHeader.addArrangedSubview(spacer())
        explorerHeader.addArrangedSubview(addFile)

        let projectRow = NSStackView()
        projectRow.orientation = .horizontal
        projectRow.alignment = .centerY
        projectRow.spacing = 0
        projectRow.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 12)
        let projectButton = NSButton(title: "", target: self, action: #selector(projectDisclosureTapped))
        projectButton.isBordered = false
        projectButton.bezelStyle = .inline
        projectButton.imagePosition = .imageLeading
        projectButton.imageScaling = .scaleProportionallyDown
        projectButton.alignment = .left
        projectButton.toolTip = "Collapse editor root"
        projectButton.setContentHuggingPriority(.required, for: .horizontal)
        projectDisclosureButton = projectButton
        updateProjectDisclosureButton()
        projectRow.addArrangedSubview(projectButton)
        projectRow.addArrangedSubview(spacer())

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Files"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 23
        outlineView.indentationPerLevel = 16
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.backgroundColor = EditorPaneDesign.chrome
        outlineView.selectionHighlightStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorPaneDesign.chrome
        fileTreeScroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarClipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )

        container.addArrangedSubview(explorerHeader)
        container.addArrangedSubview(projectRow)
        container.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return container
    }

    @objc private func projectDisclosureTapped() {
        isProjectExpanded.toggle()
        state.isProjectExpanded = isProjectExpanded
        AppEnvironment.conversationStore?.updateContent(paneID, content: .editor(state), workingDirectoryPath: state.rootPath)
        updateProjectDisclosureButton()
        outlineView.reloadData()
        if isProjectExpanded {
            outlineView.expandItem(rootNode)
            if let selected = state.selectedFilePath {
                selectFileInOutline(URL(fileURLWithPath: selected))
            }
        }
    }

    private func updateProjectDisclosureButton() {
        guard let button = projectDisclosureButton else { return }
        let symbolName = isProjectExpanded ? "chevron.down" : "chevron.right"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        button.image = image
        button.contentTintColor = EditorPaneDesign.text
        button.toolTip = isProjectExpanded ? "Collapse editor root" : "Expand editor root"
        button.attributedTitle = NSAttributedString(
            string: "  \(rootNode.displayName.uppercased())",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: EditorPaneDesign.text,
            ]
        )
        button.setAccessibilityLabel("\(isProjectExpanded ? "Collapse" : "Expand") \(rootNode.displayName)")
    }

    private func makeEditorArea() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.wantsLayer = true
        container.layer?.backgroundColor = EditorPaneDesign.surface.cgColor
        editorAreaContainer = container

        tabBar.onSelect = { [weak self] path in
            guard let self,
                  path != self.state.selectedFilePath else { return }
            self.openFile(URL(fileURLWithPath: path), userInitiated: true)
        }
        tabBar.onClose = { [weak self] path in
            self?.closeTab(path: path)
        }
        tabBar.onReorder = { [weak self] paths in
            guard let self,
                  paths != self.state.openFilePaths else { return }
            self.state.openFilePaths = paths
            AppEnvironment.conversationStore?.updateContent(
                self.paneID,
                content: .editor(self.state),
                workingDirectoryPath: self.state.rootPath
            )
        }
        tabBar.heightAnchor.constraint(equalToConstant: 32).isActive = true

        breadcrumbBar.orientation = .horizontal
        breadcrumbBar.alignment = .centerY
        breadcrumbBar.spacing = 6
        breadcrumbBar.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        breadcrumbBar.wantsLayer = true
        breadcrumbBar.layer?.backgroundColor = EditorPaneDesign.surface.cgColor
        breadcrumbBar.heightAnchor.constraint(equalToConstant: 27).isActive = true

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = Self.editorBodyFont()
        textView.backgroundColor = EditorPaneDesign.surface
        textView.textColor = EditorPaneDesign.text
        textView.insertionPointColor = EditorPaneDesign.text
        textView.selectedTextAttributes = [
            .backgroundColor: EditorPaneDesign.selected,
            .foregroundColor: EditorPaneDesign.text,
        ]
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.usesFindPanel = true

        let scroll = NSScrollView()
        // Hide system scrollers — we replace the vertical one with
        // `TerminalScrollIndicatorView` (same minimalist pill the shell
        // uses, exported public from SwiftTerm).
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorPaneDesign.surface
        // The parent container is layer-backed (wantsLayer = true), which
        // makes the scroll view layer-backed too. AppKit defaults
        // masksToBounds=false on layer-backed views, so when the user
        // scrolls up, lines that should be clipped at the scroll view's
        // top instead paint over the tab strip. Force clipping here.
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        // Assign the ruler FIRST and then the document view. NSScrollView
        // tiles its subviews when documentView is assigned; doing it in
        // this order means the textView's frame.origin.x starts at
        // ruleThickness (60) instead of 0, so the gutter doesn't paint
        // over the first characters of each line.
        let ruler = EditorLineNumberRulerView(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.documentView = textView
        scroll.tile()
        textViewScroll = scroll

        // Observe scroll-position changes via the clipView's bounds-did-change
        // notification (the standard NSScrollView pattern). updateScrollIndicator
        // also runs on initial layout and on every theme/font apply.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )

        let footer = makeFooter()
        container.addArrangedSubview(tabBar)
        container.addArrangedSubview(hairline())
        container.addArrangedSubview(scroll)
        container.addArrangedSubview(footer)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return container
    }

    private func makeFooter() -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)
        footer.wantsLayer = true
        footer.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        footer.heightAnchor.constraint(equalToConstant: 24).isActive = true
        footerView = footer

        // Save/Reload/Discard buttons + Save status text + encoding name + line ending
        // were removed from the footer. ⌘S handles save via keyboard; reload/discard
        // are rare and can come back as a context menu if needed. The status label
        // object is still kept (state machine references it) but not added to the view.
        footerLeftLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        footerRightLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        footer.addArrangedSubview(footerLeftLabel)
        footer.addArrangedSubview(spacer())
        footer.addArrangedSubview(footerRightLabel)
        return footer
    }

    @objc private func newFileTapped() {
        presentNewFilePrompt(in: newFileTargetDirectory())
    }

    private func startWatchingDirectory() {
        directoryWatcher?.stop()
        directoryWatcher = EditorDirectoryWatcher(rootURL: rootURL) { [weak self] in
            self?.scheduleFileTreeRefresh()
        }
        directoryWatcher?.start()
    }

    private func scheduleFileTreeRefresh() {
        fileTreeRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshExplorerFromDisk()
        }
        fileTreeRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func refreshExplorerFromDisk(expanding directoryPaths: Set<String> = []) {
        let expandedPaths = expandedDirectoryPaths().union(directoryPaths)
        let selectedURL = state.selectedFilePath.map { URL(fileURLWithPath: $0) }
        rootNode.invalidateChildren(recursive: true)
        if !isProjectExpanded {
            updateProjectDisclosureButton()
        }
        outlineView.reloadData()
        if isProjectExpanded {
            restoreExpandedDirectories(expandedPaths)
            if let selectedURL {
                selectFileInOutline(selectedURL)
            }
        }
        updateSidebarScrollIndicator()
    }

    private func expandedDirectoryPaths() -> Set<String> {
        var paths = Set<String>()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? EditorFileNode,
                  node.isDirectory,
                  outlineView.isItemExpanded(node) else { continue }
            paths.insert(node.url.standardizedFileURL.path)
        }
        return paths
    }

    private func restoreExpandedDirectories(_ paths: Set<String>, under node: EditorFileNode? = nil) {
        guard !paths.isEmpty else { return }
        for child in (node ?? rootNode).loadChildren() where child.isDirectory {
            if paths.contains(child.url.standardizedFileURL.path) {
                outlineView.expandItem(child)
                restoreExpandedDirectories(paths, under: child)
            }
        }
    }

    private func newFileTargetDirectory() -> URL {
        if outlineView.selectedRow >= 0,
           let node = outlineView.item(atRow: outlineView.selectedRow) as? EditorFileNode {
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }
        if let selected = state.selectedFilePath {
            return URL(fileURLWithPath: selected).deletingLastPathComponent().standardizedFileURL
        }
        return rootURL
    }

    private func presentNewFilePrompt(in directory: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "New File"
        alert.informativeText = "Create a file in \(displayPath(for: directory))."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "filename.ext"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createNewFile(named: input.stringValue, in: directory)
    }

    private func createNewFile(named rawName: String, in directory: URL) {
        let fileName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidNewFileName(fileName) else {
            showNewFileError("Enter a file name without path separators.")
            return
        }

        let destination = directory.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard isInsideEditorRoot(destination) else {
            showNewFileError("The file must be inside the editor root.")
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            showNewFileError("A file named \(fileName) already exists.")
            return
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
            showNewFileError("The file could not be created.")
            return
        }

        isProjectExpanded = true
        state.isProjectExpanded = true
        updateProjectDisclosureButton()
        refreshExplorerFromDisk(expanding: ancestorDirectoryPaths(for: destination.deletingLastPathComponent()))
        openFile(destination, userInitiated: true)
        statusLabel.stringValue = "Created \(fileName)"
    }

    private func isValidNewFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty &&
        fileName != "." &&
        fileName != ".." &&
        !fileName.contains("/") &&
        !fileName.contains(":")
    }

    private func isInsideEditorRoot(_ url: URL) -> Bool {
        let rootPath = rootURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func ancestorDirectoryPaths(for directory: URL) -> Set<String> {
        let rootPath = rootURL.path
        var paths = Set<String>()
        var cursor = directory.standardizedFileURL
        while cursor.path != rootPath && cursor.path.hasPrefix(rootPath + "/") {
            paths.insert(cursor.path)
            cursor.deleteLastPathComponent()
        }
        return paths
    }

    private func displayPath(for directory: URL) -> String {
        let rootPath = rootURL.path
        let path = directory.standardizedFileURL.path
        if path == rootPath { return rootNode.displayName }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return directory.path
    }

    private func showNewFileError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not create file"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func saveTapped() {
        saveCurrentDocument()
    }

    @objc private func reloadTapped() {
        guard let path = state.selectedFilePath else { return }
        if isDirty, !confirmDiscardUnsavedChanges() { return }
        openFile(URL(fileURLWithPath: path), line: state.selectedLine, userInitiated: false, force: true)
    }

    @objc private func discardTapped() {
        guard let path = state.selectedFilePath,
              confirmDiscardUnsavedChanges() else { return }
        openFile(URL(fileURLWithPath: path), line: state.selectedLine, userInitiated: false, force: true)
    }

    private func saveCurrentDocument() {
        guard let path = state.selectedFilePath,
              let loadedDocument else { return }
        do {
            suppressFileEventsUntil = Date().addingTimeInterval(1)
            try EditorDocumentController.save(
                text: textView.string,
                to: URL(fileURLWithPath: path),
                encoding: loadedDocument.encoding,
                lineEnding: loadedDocument.lineEnding
            )
            isDirty = false
            externalChangePending = false
            statusLabel.stringValue = "Saved"
            renderTabs()
            updateActionButtons()
            updateFooter()
            watchFile(URL(fileURLWithPath: path))
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func openFile(_ url: URL, line: Int? = nil, userInitiated: Bool, force: Bool = false) {
        let fileURL = url.standardizedFileURL
        if isDirty && !force {
            if userInitiated {
                if !confirmBeforeLeavingDirtyDocument() { return }
            } else {
                statusLabel.stringValue = "Save or discard changes before opening another file"
                return
            }
        }
        do {
            let loaded = try EditorDocumentController.load(fileURL: fileURL)
            stopWatchingFile()
            loadedDocument = loaded
            textView.string = loaded.text
            textView.undoManager?.removeAllActions()
            applyBasicHighlighting()
            // Force the layout manager to compute glyph rects for the whole
            // document before the line-number ruler draws. Doing this here
            // (rather than from within drawHashMarksAndLabels) avoids the
            // re-entrant layout that was bleeding text into the tab strip.
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            // Reset horizontal + vertical scroll to the top-left so the first
            // characters of each line aren't hidden under the gutter and the
            // user sees the document from the start.
            textView.enclosingScrollView?.contentView.scroll(to: .zero)
            textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            updateScrollIndicator()
            isDirty = false
            externalChangePending = false
            state.selectedFilePath = fileURL.path
            state.selectedLine = line
            if !state.openFilePaths.contains(fileURL.path) {
                state.openFilePaths.append(fileURL.path)
            }
            statusLabel.stringValue = loaded.encoding.localizedName ?? "Text"
            renderTabs()
            renderBreadcrumb()
            updateFooter()
            updateActionButtons()
            watchFile(fileURL)
            selectFileInOutline(fileURL)
            if let line { scrollToLine(line) }
            AppEnvironment.conversationStore?.updateContent(paneID, content: .editor(state), workingDirectoryPath: state.rootPath)
        } catch {
            loadedDocument = nil
            textView.string = ""
            state.selectedFilePath = fileURL.path
            statusLabel.stringValue = error.localizedDescription
            renderTabs()
            renderBreadcrumb()
            updateFooter()
            updateActionButtons()
        }
    }

    private func renderTabs() {
        let selected = state.selectedFilePath
        let items = currentTabPaths().map { path in
            let url = URL(fileURLWithPath: path)
            return EditorTabItem(
                path: path,
                title: url.lastPathComponent,
                symbolName: fileSymbolName(for: url),
                symbolColor: fileTint(for: url),
                isActive: path == selected,
                isDirty: isDirty && path == selected
            )
        }
        tabBar.setItems(items)
    }

    private func currentTabPaths() -> [String] {
        state.openFilePaths.isEmpty ? state.selectedFilePath.map { [$0] } ?? [] : state.openFilePaths
    }

    private func closeActiveTab() {
        guard let path = state.selectedFilePath else { return }
        closeTab(path: path)
    }

    private func closeTab(path: String) {
        if path == state.selectedFilePath && isDirty && !confirmDiscardUnsavedChanges() {
            return
        }
        state.openFilePaths.removeAll { $0 == path }
        if path == state.selectedFilePath {
            let next = state.openFilePaths.first
            state.selectedFilePath = next
            if let next {
                openFile(URL(fileURLWithPath: next), userInitiated: false, force: true)
            } else {
                stopWatchingFile()
                loadedDocument = nil
                textView.string = ""
                isDirty = false
                statusLabel.stringValue = "Select a file"
                renderBreadcrumb()
                updateFooter()
                updateActionButtons()
            }
        }
        renderTabs()
        AppEnvironment.conversationStore?.updateContent(paneID, content: .editor(state), workingDirectoryPath: state.rootPath)
    }

    private func renderBreadcrumb() {
        breadcrumbBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let path = state.selectedFilePath else {
            breadcrumbBar.addArrangedSubview(label(rootNode.displayName, size: 11, color: EditorPaneDesign.muted, weight: .regular))
            return
        }
        let root = URL(fileURLWithPath: state.rootPath, isDirectory: true).standardizedFileURL.path
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        let relative = file.hasPrefix(root + "/") ? String(file.dropFirst(root.count + 1)) : URL(fileURLWithPath: path).lastPathComponent
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            breadcrumbBar.addArrangedSubview(label(part, size: 11, color: index == parts.count - 1 ? EditorPaneDesign.text : EditorPaneDesign.muted, weight: .regular))
            if index < parts.count - 1 {
                breadcrumbBar.addArrangedSubview(symbol("chevron.right", color: EditorPaneDesign.dim, size: 11))
            }
        }
        breadcrumbBar.addArrangedSubview(spacer())
    }

    private func updateFooter() {
        let branch = currentGitBranch()
        footerLeftLabel.stringValue = branch.map { "git: \($0)" } ?? URL(fileURLWithPath: state.rootPath).lastPathComponent
        let language = languageName(for: state.selectedFilePath)
        let dirty = isDirty ? "Unsaved" : "Saved"
        footerRightLabel.stringValue = "\(dirty)   \(language)"
    }

    private func updateActionButtons() {
        saveButton.isEnabled = isDirty
        discardButton.isEnabled = isDirty
        reloadButton.isEnabled = state.selectedFilePath != nil
    }

    private func confirmBeforeLeavingDirtyDocument() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before opening another file?"
        alert.informativeText = "Your edits to \(URL(fileURLWithPath: state.selectedFilePath ?? "").lastPathComponent) have not been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            saveCurrentDocument()
            return !isDirty
        }
        return response == .alertSecondButtonReturn
    }

    private func confirmDiscardUnsavedChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "This reverts the editor buffer to the last saved version on disk."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func scrollToLine(_ line: Int) {
        let target = max(line, 1)
        var currentLine = 1
        var index = textView.string.startIndex
        while currentLine < target && index < textView.string.endIndex {
            if textView.string[index] == "\n" { currentLine += 1 }
            index = textView.string.index(after: index)
        }
        let offset = textView.string.distance(from: textView.string.startIndex, to: index)
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
    }

    /// Pre-compiled syntax-highlight regex patterns. Previously rebuilt from
    /// source strings on every keystroke (4 NSRegularExpression allocations
    /// per textDidChange). Compiled once at type-load.
    private static let highlightPatterns: [(NSRegularExpression, NSColor)] = {
        let entries: [(String, NSColor)] = [
            (#"\b(class|struct|enum|func|let|var|if|else|switch|case|for|while|return|import|final|private|public|internal|try|catch|throw|throws|async|await|guard|extension|protocol)\b"#, EditorPaneDesign.blue),
            (#""([^"\\]|\\.)*""#, EditorPaneDesign.green),
            (#"//.*$"#, EditorPaneDesign.dim),
            (#"\b[0-9]+(\.[0-9]+)?\b"#, EditorPaneDesign.yellow),
        ]
        return entries.compactMap { pattern, color in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                return nil
            }
            return (regex, color)
        }
    }()

    /// Apply syntax highlighting to a range (default: whole document).
    /// Called full-doc on file load and theme change; called per-edit on
    /// text changes via the NSTextStorageDelegate hook below.
    private func applyBasicHighlighting(in targetRange: NSRange? = nil) {
        guard let storage = textView.textStorage else { return }
        let range = targetRange ?? NSRange(location: 0, length: storage.length)
        guard range.length > 0, range.upperBound <= storage.length else { return }
        storage.setAttributes([
            .foregroundColor: EditorPaneDesign.text,
            .font: Self.editorBodyFont(),
        ], range: range)
        for (regex, color) in Self.highlightPatterns {
            regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }

    /// Incremental highlight on text edits. Guard on `.editedCharacters`
    /// avoids reentrancy: our own setAttributes/addAttribute calls below
    /// re-fire this delegate with `.editedAttributes` only, which we skip.
    /// Range is expanded to full line(s) so the string-literal and
    /// line-comment regexes see complete context.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let expanded = (textStorage.string as NSString).lineRange(for: editedRange)
        applyBasicHighlighting(in: expanded)
    }

    private func watchFile(_ url: URL) {
        stopWatchingFile()
        watcherFD = open(url.path, O_EVTONLY)
        guard watcherFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watcherFD,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let suppressFileEventsUntil = self.suppressFileEventsUntil {
                if Date() < suppressFileEventsUntil { return }
                self.suppressFileEventsUntil = nil
            }
            self.externalChangePending = true
            self.statusLabel.stringValue = self.isDirty ? "Changed on disk and unsaved" : "Changed on disk. Reload available"
            self.updateFooter()
        }
        source.setCancelHandler { [fd = watcherFD] in
            if fd >= 0 { close(fd) }
        }
        watcher = source
        source.resume()
    }

    private func stopWatchingFile() {
        watcher?.cancel()
        watcher = nil
        watcherFD = -1
    }

    func textDidChange(_ notification: Notification) {
        isDirty = true
        statusLabel.stringValue = externalChangePending ? "Unsaved, disk changed" : "Unsaved"
        // applyBasicHighlighting no longer called here; the
        // NSTextStorageDelegate hook above runs incrementally on the
        // edited line range only — full-doc re-highlight per keystroke
        // (300ms–1s on 10k-line files) replaced by per-line work.
        renderTabs()
        updateFooter()
        updateActionButtons()
        textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil && !isProjectExpanded { return 0 }
        return (item as? EditorFileNode ?? rootNode).loadChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? EditorFileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? EditorFileNode ?? rootNode).loadChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? EditorFileNode else { return nil }
        let cell = NSTableCellView()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(symbol(fileSymbolName(for: node.url, isDirectory: node.isDirectory), color: node.isDirectory ? EditorPaneDesign.blue : fileTint(for: node.url), size: node.isDirectory ? 12 : 14))
        let label = label(node.displayName, size: 12, color: colorForNode(node), weight: .regular)
        row.addArrangedSubview(label)
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? EditorFileNode,
              !node.isDirectory else { return }
        openFile(node.url, userInitiated: true)
    }

    private func selectFileInOutline(_ fileURL: URL) {
        let normalized = fileURL.standardizedFileURL.path
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? EditorFileNode else { continue }
            if node.url.standardizedFileURL.path == normalized {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                return
            }
        }
    }

    private func colorForNode(_ node: EditorFileNode) -> NSColor {
        if node.url.path == state.selectedFilePath { return EditorPaneDesign.blue }
        return node.isDirectory ? EditorPaneDesign.text : EditorPaneDesign.muted
    }

    private func fileSymbolName(for url: URL, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "rs", "go", "c", "cc", "cpp", "h", "m", "mm":
            return "curlybraces"
        case "md", "txt", "rst":
            return "doc.text"
        case "json", "yml", "yaml", "toml":
            return "doc.badge.gearshape"
        default:
            return "doc"
        }
    }

    private func fileTint(for url: URL) -> NSColor {
        switch url.pathExtension.lowercased() {
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "rs", "go":
            return EditorPaneDesign.orange
        case "json", "yml", "yaml", "toml":
            return EditorPaneDesign.yellow
        default:
            return EditorPaneDesign.muted
        }
    }

    private func languageName(for path: String?) -> String {
        guard let ext = path.map({ URL(fileURLWithPath: $0).pathExtension.lowercased() }) else { return "Text" }
        switch ext {
        case "swift": return "Swift"
        case "js": return "JavaScript"
        case "ts": return "TypeScript"
        case "tsx", "jsx": return "React"
        case "py": return "Python"
        case "md": return "Markdown"
        case "json": return "JSON"
        case "yml", "yaml": return "YAML"
        default: return ext.isEmpty ? "Text" : ext.uppercased()
        }
    }

    private func currentGitBranch() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", state.rootPath, "branch", "--show-current"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let branch = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return branch?.isEmpty == false ? branch : "detached"
        } catch {
            return nil
        }
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func hairline() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = EditorPaneDesign.border.cgColor
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func label(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    private func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        let imageView = NSImageView(image: image)
        imageView.contentTintColor = color
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        imageView.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: size + 2).isActive = true
        return imageView
    }

    private func iconButton(_ symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.image?.isTemplate = true
        button.contentTintColor = EditorPaneDesign.muted
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    // MARK: - Agent integration

    private func wireEditorTextViewHandlers() {
        textView.contextProvider = { [weak self] in
            guard let self else { return (nil, nil) }
            return (self.state.selectedFilePath, self.state.rootPath)
        }
        textView.askAgentHandler = { [weak self] selectedText, filePath, _ in
            guard let self else { return }
            let prompt = self.buildAskAgentPrompt(selectedText: selectedText, filePath: filePath)
            self.sendToSiblingAgent(prompt)
        }
        textView.saveHandler = { [weak self] in
            self?.saveCurrentDocument()
        }
        textView.closeTabHandler = { [weak self] in
            self?.closeActiveTab()
        }
        textView.openFileFinderHandler = { [weak self] in
            self?.showFileFinder()
        }
        textView.toggleSidebarHandler = { [weak self] in
            self?.toggleSidebar()
        }
    }

    private var fileFinder: EditorFileFinderWindowController?

    private func showFileFinder() {
        let finder = fileFinder ?? EditorFileFinderWindowController(
            rootURL: URL(fileURLWithPath: state.rootPath, isDirectory: true)
        )
        fileFinder = finder
        finder.onSelect = { [weak self] url in
            self?.openFile(url, userInitiated: true)
        }
        finder.present(from: view.window)
    }

    private func buildAskAgentPrompt(selectedText: String, filePath: String?) -> String {
        let relPath = filePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
        let ext = filePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let sel = textView.selectedRange()
        var lineContext = ""
        if sel.length > 0 {
            let prefix = (textView.string as NSString).substring(to: sel.location)
            let startLine = prefix.components(separatedBy: "\n").count
            let endLine = startLine + selectedText.components(separatedBy: "\n").count - 1
            lineContext = startLine == endLine ? "L\(startLine)" : "L\(startLine)–\(endLine)"
        }
        let fileTag = relPath.isEmpty ? "" : (lineContext.isEmpty ? "`\(relPath)`" : "`\(relPath):\(lineContext)`")
        let header = fileTag.isEmpty ? "" : "File: \(fileTag)\n\n"
        let fence = ext.isEmpty ? "```" : "```\(ext)"
        return "What does this code do?\n\n\(header)\(fence)\n\(selectedText)\n```"
    }

    private func sendToSiblingAgent(_ text: String) {
        guard let store = AppEnvironment.conversationStore else { return }
        guard let myConv = store.conversation(paneID) else { return }
        let terminals = store.conversations(in: myConv.workspaceID).filter { $0.content.isTerminal }
        guard let sibling = terminals.first else { return }
        guard let pvc = LivePaneRegistry.shared.pane(for: sibling.id) as? PaneViewController else { return }
        pvc.terminalView.brokerSend(text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak pvc] in
            pvc?.terminalView.brokerSendEnterKey()
        }
    }

}
