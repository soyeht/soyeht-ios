import AppKit
import Foundation
import SoyehtCore
import SwiftTerm

/// Editor palette derived from the user's active `TerminalColorTheme`
/// (iTerm2-Color-Schemes catalog). All tokens flow through `MacTheme` so
/// the editor follows whatever theme the user picked in Preferences →
/// Appearance, and recomputes on `.preferencesDidChange`.
///
/// `chrome` is intentionally a subtle lift/recess from `surface` so the
/// sidebar, tab strip and footer read as a separate plane from the editor
/// body — same elevation convention as Xcode/VS Code. The shift is small
/// (≈6% toward white on dark themes, ≈4% toward black on light themes)
/// so the WCAG contrast of `text`-on-`chrome` is preserved.
private enum EditorPaneDesign {
    static var surface: NSColor { MacTheme.surfaceBase }
    static var surfaceDeep: NSColor { MacTheme.surfaceBase }
    static var surfaceRaised: NSColor { MacTheme.tabActiveFill }
    static var selected: NSColor { MacTheme.selection }
    static var currentLine: NSColor { MacTheme.surfaceBase }
    static var border: NSColor { MacTheme.borderIdle }
    static var text: NSColor { MacTheme.readableTextOnBackground }
    static var muted: NSColor { MacTheme.readableSecondaryTextOnBackground }
    static var dim: NSColor { MacTheme.readableSecondaryTextOnBackground }
    static var blue: NSColor { MacTheme.accentBlue }
    static var orange: NSColor { MacTheme.accentAmber }
    static var yellow: NSColor { MacTheme.accentAmber }
    static var green: NSColor { MacTheme.accentGreenEmerald }
    static var red: NSColor { MacTheme.accentRed }

    /// Lifted/recessed surface for sidebar + tab strip + footer.
    static var chrome: NSColor {
        let base = MacTheme.surfaceBase
        let palette = TerminalColorTheme.active.appPalette
        let target: NSColor = palette.isDark ? .white : .black
        let fraction: CGFloat = palette.isDark ? 0.06 : 0.04
        return base.blended(withFraction: fraction, of: target) ?? base
    }
}

private final class EditorFileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    private(set) var children: [EditorFileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
    }

    var displayName: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    func loadChildren() -> [EditorFileNode] {
        guard isDirectory else { return [] }
        if let children { return children }
        let skipped = Set([".git", ".build", ".swiftpm", "DerivedData", "node_modules"])
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )) ?? []
        let loaded = urls
            .filter { !skipped.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".DS_Store") }
            .map { childURL -> EditorFileNode in
                let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey])
                return EditorFileNode(url: childURL, isDirectory: values?.isDirectory == true)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        children = loaded
        return loaded
    }

    func invalidateChildren() {
        children = nil
    }
}

@MainActor
final class EditorPaneViewController: NSViewController, PaneContentViewControlling, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate {
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
    private let outlineView = NSOutlineView()
    private let textView = EditorTextView()
    private let tabStrip = NSStackView()
    private let breadcrumbBar = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLeftLabel = NSTextField(labelWithString: "")
    private let footerRightLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private var sidebarContainer: NSStackView?
    private var explorerHeader: NSStackView?
    private var fileTreeScroll: NSScrollView?
    private var editorAreaContainer: NSStackView?
    private var textViewScroll: NSScrollView?
    private var footerView: NSStackView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var scrollIndicator: TerminalScrollIndicatorView?
    private var sidebarScrollIndicator: TerminalScrollIndicatorView?
    private static let sidebarExpandedWidth: CGFloat = 240
    private static let scrollIndicatorWidth: CGFloat = 15
    private var loadedDocument: EditorLoadedDocument?
    private var isDirty = false
    private var externalChangePending = false
    private var suppressFileEventsUntil: Date?
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: CInt = -1

    init(paneID: Conversation.ID, state: EditorPaneState) {
        self.paneID = paneID
        self.state = state
        let rootURL = URL(fileURLWithPath: state.rootPath, isDirectory: true).standardizedFileURL
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = ArrowCursorView()
        root.wantsLayer = true
        root.layer?.backgroundColor = EditorPaneDesign.surface.cgColor

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(makeSidebar())
        split.addArrangedSubview(makeEditorArea())
        if let first = split.arrangedSubviews.first {
            let widthConstraint = first.widthAnchor.constraint(equalToConstant: Self.sidebarExpandedWidth)
            widthConstraint.isActive = true
            sidebarWidthConstraint = widthConstraint
        }

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
        outlineView.reloadData()
        outlineView.expandItem(rootNode)
        renderTabs()
        renderBreadcrumb()
        if let selected = state.selectedFilePath {
            openFile(URL(fileURLWithPath: selected), line: state.selectedLine, userInitiated: false)
        } else {
            statusLabel.stringValue = "Select a file"
            updateFooter()
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
        fileTreeScroll?.backgroundColor = EditorPaneDesign.chrome
        outlineView.backgroundColor = EditorPaneDesign.chrome

        // Top + bottom chrome
        tabStrip.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
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
        guard let constraint = sidebarWidthConstraint else { return }
        let target: CGFloat = constraint.constant > 0 ? 0 : Self.sidebarExpandedWidth
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            constraint.animator().constant = target
            self.view.layoutSubtreeIfNeeded()
        }
    }

    func updateContent(_ content: PaneContent) {
        guard case .editor(let newState) = content else { return }
        let previousFile = state.selectedFilePath
        if let selected = newState.selectedFilePath,
           selected != previousFile {
            openFile(URL(fileURLWithPath: selected), line: newState.selectedLine, userInitiated: false)
            return
        }
        state = newState
        renderTabs()
        renderBreadcrumb()
        if let line = newState.selectedLine {
            scrollToLine(line)
        }
    }

    func prepareForClose() {
        stopWatchingFile()
    }

    private func makeSidebar() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
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
        let refresh = iconButton("arrow.clockwise", action: #selector(refreshExplorerTapped))
        explorerHeader.addArrangedSubview(title)
        explorerHeader.addArrangedSubview(spacer())
        explorerHeader.addArrangedSubview(refresh)

        let projectRow = NSStackView()
        projectRow.orientation = .horizontal
        projectRow.alignment = .centerY
        projectRow.spacing = 4
        projectRow.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 12)
        projectRow.addArrangedSubview(symbol("chevron.down", color: EditorPaneDesign.text, size: 12))
        projectRow.addArrangedSubview(label(rootNode.displayName.uppercased(), size: 11, color: EditorPaneDesign.text, weight: .bold))

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

    private func makeEditorArea() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.wantsLayer = true
        container.layer?.backgroundColor = EditorPaneDesign.surface.cgColor
        editorAreaContainer = container

        tabStrip.orientation = .horizontal
        tabStrip.alignment = .centerY
        tabStrip.spacing = 0
        tabStrip.wantsLayer = true
        tabStrip.layer?.backgroundColor = EditorPaneDesign.chrome.cgColor
        tabStrip.heightAnchor.constraint(equalToConstant: 32).isActive = true

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
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
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
        container.addArrangedSubview(tabStrip)
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

    @objc private func refreshExplorerTapped() {
        rootNode.invalidateChildren()
        outlineView.reloadData()
        outlineView.expandItem(rootNode)
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
        tabStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let selected = state.selectedFilePath
        let paths = state.openFilePaths.isEmpty ? selected.map { [$0] } ?? [] : state.openFilePaths
        for path in paths {
            tabStrip.addArrangedSubview(makeTab(path: path, active: path == selected))
        }
        tabStrip.addArrangedSubview(spacer())
    }

    private func makeTab(path: String, active: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = (active ? EditorPaneDesign.surface : EditorPaneDesign.chrome).cgColor
        row.layer?.borderWidth = active ? 0 : 0.5
        row.layer?.borderColor = EditorPaneDesign.border.cgColor
        row.identifier = NSUserInterfaceItemIdentifier(path)

        row.addArrangedSubview(symbol(fileSymbolName(for: URL(fileURLWithPath: path)), color: fileTint(for: URL(fileURLWithPath: path)), size: 13))
        let name = label((isDirty && active ? "● " : "") + URL(fileURLWithPath: path).lastPathComponent, size: 12, color: active ? .white : EditorPaneDesign.muted, weight: .regular)
        row.addArrangedSubview(name)
        let close = iconButton("xmark", action: #selector(closeTabTapped(_:)))
        close.identifier = NSUserInterfaceItemIdentifier(path)
        row.addArrangedSubview(close)

        let click = NSClickGestureRecognizer(target: self, action: #selector(tabClicked(_:)))
        row.addGestureRecognizer(click)
        return row
    }

    @objc private func tabClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let row = recognizer.view,
              let path = row.identifier?.rawValue else { return }
        // The row's NSClickGestureRecognizer consumes mouse events before
        // child NSButtons can track them, so the close X never fires its
        // own action. Detect the hit and dispatch the close action here.
        let windowPoint = recognizer.location(in: nil)
        let rowPoint = row.convert(windowPoint, from: nil)
        if let closeButton = row.subviews.first(where: { $0 is NSButton && $0.frame.contains(rowPoint) }) as? NSButton {
            closeTabTapped(closeButton)
            return
        }
        guard path != state.selectedFilePath else { return }
        openFile(URL(fileURLWithPath: path), userInitiated: true)
    }

    @objc private func closeTabTapped(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
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

    private func applyBasicHighlighting() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .foregroundColor: EditorPaneDesign.text,
            .font: Self.editorBodyFont(),
        ], range: full)

        let patterns: [(String, NSColor)] = [
            (#"\b(class|struct|enum|func|let|var|if|else|switch|case|for|while|return|import|final|private|public|internal|try|catch|throw|throws|async|await|guard|extension|protocol)\b"#, EditorPaneDesign.blue),
            (#""([^"\\]|\\.)*""#, EditorPaneDesign.green),
            (#"//.*$"#, EditorPaneDesign.dim),
            (#"\b[0-9]+(\.[0-9]+)?\b"#, EditorPaneDesign.yellow),
        ]
        for (pattern, color) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                    guard let match else { return }
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
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
        applyBasicHighlighting()
        renderTabs()
        updateFooter()
        updateActionButtons()
        textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? EditorFileNode ?? rootNode).loadChildren().count
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

// MARK: - EditorTextView

private final class EditorTextView: NSTextView {
    var contextProvider: (() -> (String?, String?))?
    var askAgentHandler: ((String, String?, String?) -> Void)?
    var saveHandler: (() -> Void)?
    var openFileFinderHandler: (() -> Void)?
    var toggleSidebarHandler: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "s" {
            saveHandler?()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "p" {
            openFileFinderHandler?()
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "b" {
            toggleSidebarHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Auto-pair brackets and quotes. Hooks into `insertText` so it composes
    /// with paste, IME, autocomplete, and undo without re-implementing the
    /// text storage write path.
    /// - Opening char (`{`, `(`, `[`, `"`, `'`, `` ` ``) inserts the pair and
    ///   leaves the cursor between them.
    /// - Typing the closing char when it's already the next character moves
    ///   the cursor over it instead of duplicating, so the user can "type
    ///   through" the auto-inserted close.
    /// - Quotes are skipped when adjacent to a word char to avoid breaking
    ///   apostrophes mid-word (don't, it's).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard selectedRange().length == 0,
              let typed = (string as? String) ?? (string as? NSAttributedString)?.string,
              typed.count == 1,
              let scalar = typed.unicodeScalars.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let ch = Character(scalar)
        let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]", "\"": "\"", "'": "'", "`": "`"]
        let closersFromPair = Set(pairs.values)
        let nsText = self.string as NSString
        let caret = selectedRange().location

        // Skip-through: if the next char is the same closer we're typing,
        // just move the cursor — don't double it.
        if closersFromPair.contains(ch),
           caret < nsText.length,
           Character(nsText.substring(with: NSRange(location: caret, length: 1))) == ch {
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return
        }

        guard let closing = pairs[ch] else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // For quotes only: don't pair when adjacent to a word char (so the
        // apostrophe in "don't" still works).
        if ch == "\"" || ch == "'" || ch == "`" {
            let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            if caret > 0,
               let prevScalar = nsText.substring(with: NSRange(location: caret - 1, length: 1)).unicodeScalars.first,
               wordChars.contains(prevScalar) {
                super.insertText(string, replacementRange: replacementRange)
                return
            }
        }

        super.insertText("\(ch)\(closing)", replacementRange: replacementRange)
        // After insertion the caret is at end; move it back between the pair.
        let newCaret = selectedRange().location - 1
        setSelectedRange(NSRange(location: newCaret, length: 0))
    }

    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { super.copy(sender); return }
        let nsText = string as NSString
        let selectedText = nsText.substring(with: sel)
        let (filePath, rootPath) = contextProvider?() ?? (nil, nil)

        let prefix = nsText.substring(to: sel.location)
        let startLine = prefix.components(separatedBy: "\n").count
        let endLine = startLine + selectedText.components(separatedBy: "\n").count - 1
        let lineTag = startLine == endLine ? "L\(startLine)" : "L\(startLine)–\(endLine)"

        let relPath = filePath.map { ($0 as NSString).standardizingPath } ?? ""

        let header = relPath.isEmpty ? "" : "`\(relPath):\(lineTag)`\n\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + selectedText, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        guard selectedRange().length > 0 else { return base }
        let item = NSMenuItem(title: "Ask agent what this does", action: #selector(askAgentAboutSelection(_:)), keyEquivalent: "")
        item.target = self
        base.insertItem(item, at: 0)
        base.insertItem(.separator(), at: 1)
        return base
    }

    @objc private func askAgentAboutSelection(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        let selectedText = (string as NSString).substring(with: sel)
        let (filePath, rootPath) = contextProvider?() ?? (nil, nil)
        askAgentHandler?(selectedText, filePath, rootPath)
    }
}

/// NSView subclass that registers an `.arrow` cursor rect for its bounds.
/// Used as the editor pane's root so the I-beam from the inner NSTextView
/// stops "leaking" into the tab strip / sidebar / footer / gutter chrome.
/// AppKit picks the deepest view's cursor rect for the cursor position,
/// so the textView still shows I-beam where it should — everything else
/// resolves to arrow.
private final class ArrowCursorView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

private final class EditorLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var gutterFontSize: CGFloat = 11

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 60
        gutterFontSize = max(9, TerminalPreferences.shared.fontSize * 0.85)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    /// Update only the gutter FONT — width stays fixed at 60pt so the scroll
    /// view's tiling stays put. (Mutating ruleThickness post-attach desyncs
    /// the document view origin from the gutter and clips the first chars
    /// of each line; not worth the complexity for a marginally wider gutter
    /// at very large font sizes.)
    func applyMetrics(bodySize: CGFloat) {
        gutterFontSize = max(9, bodySize * 0.85)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorPaneDesign.surfaceDeep.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager else { return }

        // NOTE: Layout completion is forced from `EditorPaneViewController.openFile`
        // after the text is set, not here. Calling `ensureLayout` during draw is
        // re-entrant and was making the text view bleed pixels into the tab strip
        // when the user scrolled.

        // Iterate source lines directly instead of going through
        // `glyphRange(forBoundingRect:)`. The bounding-rect form was
        // skipping the first 1–14 line numbers at large font sizes
        // because the visible-rect-to-glyph-range mapping had a small
        // offset bug. Visibility culling is now done per-line on Y.
        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let text = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: gutterFontSize, weight: .regular),
            .foregroundColor: EditorPaneDesign.dim,
        ]

        let topY = visibleRect.minY
        let bottomY = visibleRect.maxY
        var lineNumber = 1
        var index = 0
        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if lineGlyphRange.length > 0 {
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lineGlyphRange.location, effectiveRange: nil)
                let lineTop = textView.textContainerOrigin.y + lineRect.minY
                if lineTop > bottomY { break }
                if lineTop + lineRect.height >= topY {
                    let label = "\(lineNumber)" as NSString
                    let size = label.size(withAttributes: attrs)
                    label.draw(
                        at: NSPoint(x: max(4, ruleThickness - size.width - 9), y: lineTop - topY),
                        withAttributes: attrs
                    )
                }
            }
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
    }
}

private extension String.Encoding {
    var localizedName: String? {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        default: return nil
        }
    }
}

// MARK: - File Finder (⌘P)

/// Spotlight-style fuzzy file finder scoped to the editor pane's root.
/// Mirrors `CommandPaletteWindowController` chrome (NSPanel, search field +
/// table, MacTheme tokens) so both palettes feel like the same surface.
@MainActor
final class EditorFileFinderWindowController: NSWindowController {

    struct FileItem {
        let url: URL
        let filename: String
        let relativePath: String
    }

    private let rootURL: URL
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private var allFiles: [FileItem] = []
    private var displayedFiles: [FileItem] = []

    var onSelect: ((URL) -> Void)?

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false

        super.init(window: panel)

        panel.contentView = buildContentView()
        searchField.delegate = self
        tableView.delegate = self
        tableView.dataSource = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func present(from parentWindow: NSWindow?) {
        scanFilesIfNeeded()
        if let parent = parentWindow, let panel = window {
            let parentFrame = parent.frame
            let panelSize = panel.frame.size
            let x = parentFrame.minX + (parentFrame.width - panelSize.width) / 2
            let y = parentFrame.minY + parentFrame.height - panelSize.height - 120
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        searchField.stringValue = ""
        rerank()
        showWindow(nil)
        window?.makeKey()
        window?.makeFirstResponder(searchField)
    }

    private func buildContentView() -> NSView {
        let root = ArrowCursorView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacTheme.surfaceBase.cgColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = MacTypography.NSFonts.commandPaletteSearch
        searchField.placeholderString = "Find file in project"
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.textColor = MacTheme.textPrimary
        searchField.focusRingType = .none

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        tableView.addTableColumn(NSTableColumn(identifier: .init("primary")))
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.target = self
        tableView.doubleAction = #selector(rowConfirmed)
        scroll.documentView = tableView

        root.addSubview(searchField)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        return root
    }

    private func scanFilesIfNeeded() {
        // Rescan if empty (first show) or if root changed — keep dataset
        // hot otherwise so subsequent ⌘P pops are instant.
        guard allFiles.isEmpty else { return }
        let fm = FileManager.default
        let skip: Set<String> = [".git", ".build", ".swiftpm", "DerivedData", "node_modules", ".next", ".turbo", "dist"]
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        let rootPath = rootURL.path
        var collected: [FileItem] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if skip.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            let std = fileURL.standardizedFileURL.path
            let relative = std.hasPrefix(rootPath + "/") ? String(std.dropFirst(rootPath.count + 1)) : std
            collected.append(FileItem(url: fileURL, filename: name, relativePath: relative))
            if collected.count >= 5000 { break }
        }
        allFiles = collected
    }

    private func rerank() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            displayedFiles = Array(
                allFiles
                    .sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
                    .prefix(200)
            )
        } else {
            let q = query.lowercased()
            let scored: [(FileItem, Int)] = allFiles.compactMap { item in
                let s = Self.fuzzyScore(query: q, item: item)
                return s > 0 ? (item, s) : nil
            }
            displayedFiles = Array(
                scored
                    .sorted { $0.1 > $1.1 }
                    .prefix(200)
                    .map { $0.0 }
            )
        }
        tableView.reloadData()
        if !displayedFiles.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Cheap fuzzy match that mirrors VS Code / Sublime's heuristics:
    /// filename prefix > filename substring > filename subsequence > path
    /// subsequence. Shorter filenames win at tie because they're "closer"
    /// to what the user typed.
    private static func fuzzyScore(query: String, item: FileItem) -> Int {
        let filename = item.filename.lowercased()
        let path = item.relativePath.lowercased()
        if filename == query { return 10_000 }
        if filename.hasPrefix(query) { return 5_000 - filename.count }
        if filename.contains(query) { return 2_000 - filename.count }
        if Self.isSubsequence(query, of: filename) { return 1_000 - filename.count }
        if Self.isSubsequence(query, of: path) { return 500 - path.count }
        return 0
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var i = needle.startIndex
        for ch in haystack where i < needle.endIndex && ch == needle[i] {
            i = needle.index(after: i)
        }
        return i == needle.endIndex
    }

    @objc private func rowConfirmed() {
        commitSelection()
    }

    private func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < displayedFiles.count else { return }
        let item = displayedFiles[row]
        close()
        onSelect?(item.url)
    }
}

extension EditorFileFinderWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        rerank()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: +1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !displayedFiles.isEmpty else { return }
        let current = tableView.selectedRow
        let next = max(0, min(displayedFiles.count - 1, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

extension EditorFileFinderWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedFiles.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("EditorFileFinderRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? EditorFileFinderRowView)
            ?? {
                let v = EditorFileFinderRowView()
                v.identifier = identifier
                return v
            }()
        cell.configure(with: displayedFiles[row])
        return cell
    }
}

@MainActor
private final class EditorFileFinderRowView: NSTableCellView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.font = MacTypography.NSFonts.commandPalettePrimary
        primaryLabel.textColor = MacTheme.textPrimary
        primaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.font = MacTypography.NSFonts.commandPaletteSecondary
        secondaryLabel.textColor = MacTheme.textSecondary
        secondaryLabel.lineBreakMode = .byTruncatingHead
        addSubview(primaryLabel)
        addSubview(secondaryLabel)
        NSLayoutConstraint.activate([
            primaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            primaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            secondaryLabel.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 2),
            secondaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: EditorFileFinderWindowController.FileItem) {
        primaryLabel.stringValue = item.filename
        secondaryLabel.stringValue = item.relativePath
    }
}
