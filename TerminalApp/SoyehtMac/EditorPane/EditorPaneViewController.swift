import AppKit
import Foundation

private enum EditorPaneDesign {
    static let chrome = NSColor(soyehtRequiredHex: "#181A22")
    static let surface = NSColor(soyehtRequiredHex: "#1D1F28")
    static let surfaceDeep = NSColor(soyehtRequiredHex: "#1A1C24")
    static let surfaceRaised = NSColor(soyehtRequiredHex: "#252731")
    static let selected = NSColor(soyehtRequiredHex: "#2D3142")
    static let currentLine = NSColor(soyehtRequiredHex: "#262833")
    static let border = NSColor(soyehtRequiredHex: "#262833")
    static let text = NSColor(soyehtRequiredHex: "#C8CDD8")
    static let muted = NSColor(soyehtRequiredHex: "#8A92A5")
    static let dim = NSColor(soyehtRequiredHex: "#555B6E")
    static let blue = NSColor(soyehtRequiredHex: "#5B9CF6")
    static let orange = NSColor(soyehtRequiredHex: "#FF8A65")
    static let yellow = NSColor(soyehtRequiredHex: "#FFD66B")
    static let green = NSColor(soyehtRequiredHex: "#98C379")
    static let red = NSColor(soyehtRequiredHex: "#E06C75")
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
    private let textView = NSTextView()
    private let tabStrip = NSStackView()
    private let breadcrumbBar = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLeftLabel = NSTextField(labelWithString: "")
    private let footerRightLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = EditorPaneDesign.surface.cgColor

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(makeSidebar())
        split.addArrangedSubview(makeEditorArea())
        split.arrangedSubviews.first?.widthAnchor.constraint(equalToConstant: 240).isActive = true

        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
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
        view.layer?.backgroundColor = EditorPaneDesign.surface.cgColor
        textView.backgroundColor = EditorPaneDesign.surface
        textView.textColor = EditorPaneDesign.text
        textView.insertionPointColor = EditorPaneDesign.text
        outlineView.backgroundColor = EditorPaneDesign.surface
        statusLabel.textColor = EditorPaneDesign.muted
        footerLeftLabel.textColor = EditorPaneDesign.muted
        footerRightLabel.textColor = EditorPaneDesign.muted
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
        container.layer?.backgroundColor = EditorPaneDesign.surface.cgColor

        let explorerHeader = NSStackView()
        explorerHeader.orientation = .horizontal
        explorerHeader.alignment = .centerY
        explorerHeader.spacing = 8
        explorerHeader.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 16)
        explorerHeader.wantsLayer = true
        explorerHeader.layer?.backgroundColor = EditorPaneDesign.surface.cgColor

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
        outlineView.backgroundColor = EditorPaneDesign.surface
        outlineView.selectionHighlightStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorPaneDesign.surface

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
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorPaneDesign.surface
        scroll.verticalRulerView = EditorLineNumberRulerView(textView: textView)

        let footer = makeFooter()
        container.addArrangedSubview(tabStrip)
        container.addArrangedSubview(hairline())
        container.addArrangedSubview(breadcrumbBar)
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

        [saveButton, reloadButton, discardButton].forEach {
            $0.bezelStyle = .inline
            $0.controlSize = .small
            $0.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        }
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        reloadButton.target = self
        reloadButton.action = #selector(reloadTapped)
        discardButton.target = self
        discardButton.action = #selector(discardTapped)

        footerLeftLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        footerRightLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        footer.addArrangedSubview(footerLeftLabel)
        footer.addArrangedSubview(saveButton)
        footer.addArrangedSubview(reloadButton)
        footer.addArrangedSubview(discardButton)
        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(spacer())
        footer.addArrangedSubview(footerRightLabel)
        updateActionButtons()
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
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
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
              let path = row.identifier?.rawValue,
              path != state.selectedFilePath else { return }
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
        let ending = loadedDocument?.lineEnding == "\r\n" ? "CRLF" : "LF"
        let encoding = loadedDocument?.encoding.localizedName ?? "UTF-8"
        let language = languageName(for: state.selectedFilePath)
        let dirty = isDirty ? "Unsaved" : "Saved"
        footerRightLabel.stringValue = "\(dirty)   \(ending)   \(encoding)   \(language)"
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
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
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
}

private final class EditorLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorPaneDesign.surfaceDeep.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard glyphRange.length > 0 else { return }

        let text = textView.string as NSString
        var lineNumber = 1
        if glyphRange.location > 0 {
            let prefix = NSRange(location: 0, length: min(glyphRange.location, text.length))
            text.enumerateSubstrings(in: prefix, options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                lineNumber += 1
            }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: EditorPaneDesign.dim,
        ]
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lineGlyphRange.location, effectiveRange: nil)
            let y = textView.textContainerOrigin.y + lineRect.minY - visibleRect.minY
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: NSPoint(x: max(4, ruleThickness - size.width - 9), y: y),
                withAttributes: attrs
            )
            glyphIndex = NSMaxRange(lineGlyphRange)
            lineNumber += 1
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
