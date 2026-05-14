import AppKit
import Foundation

private enum GitPaneDesign {
    static let chrome = NSColor(soyehtRequiredHex: "#181A22")
    static let surface = NSColor(soyehtRequiredHex: "#1D1F28")
    static let surfaceDeep = NSColor(soyehtRequiredHex: "#1A1C24")
    static let surfaceRaised = NSColor(soyehtRequiredHex: "#252731")
    static let selected = NSColor(soyehtRequiredHex: "#2D3142")
    static let border = NSColor(soyehtRequiredHex: "#262833")
    static let text = NSColor(soyehtRequiredHex: "#C8CDD8")
    static let brightText = NSColor(soyehtRequiredHex: "#FAFAFA")
    static let muted = NSColor(soyehtRequiredHex: "#8A92A5")
    static let dim = NSColor(soyehtRequiredHex: "#555B6E")
    static let blue = NSColor(soyehtRequiredHex: "#5B9CF6")
    static let hunkBlue = NSColor(soyehtRequiredHex: "#7DCFFF")
    static let yellow = NSColor(soyehtRequiredHex: "#FFD66B")
    static let branchYellow = NSColor(soyehtRequiredHex: "#F59E0B")
    static let green = NSColor(soyehtRequiredHex: "#98C379")
    static let greenText = NSColor(soyehtRequiredHex: "#A5D6A7")
    static let greenBackground = NSColor(soyehtRequiredHex: "#1F3A26")
    static let red = NSColor(soyehtRequiredHex: "#E06C75")
    static let redText = NSColor(soyehtRequiredHex: "#E5989B")
    static let redBackground = NSColor(soyehtRequiredHex: "#3A1F22")
    static let hunkBackground = NSColor(soyehtRequiredHex: "#1A2330")
    static let badgeBackground = NSColor(soyehtRequiredHex: "#2D3045")
}

private enum GitSidebarSection: CaseIterable, Hashable {
    case staged
    case changes
    case untracked

    var title: String {
        switch self {
        case .staged: return "STAGED CHANGES"
        case .changes: return "CHANGES"
        case .untracked: return "UNTRACKED"
        }
    }

    var scope: GitDiffScope {
        switch self {
        case .staged: return .staged
        case .changes, .untracked: return .unstaged
        }
    }

    var preferStagedBadge: Bool {
        self == .staged
    }

    func files(in snapshot: GitRepositorySnapshot) -> [GitChangedFile] {
        switch self {
        case .staged: return snapshot.stagedFiles
        case .changes: return snapshot.unstagedFiles
        case .untracked: return snapshot.untrackedFiles
        }
    }
}

private enum GitSidebarRow {
    case section(GitSidebarSection, count: Int)
    case file(GitChangedFile, GitSidebarSection)
}

@MainActor
final class GitPaneViewController: NSViewController, PaneContentViewControlling, NSTableViewDataSource, NSTableViewDelegate {
    let paneID: Conversation.ID
    let contentKind: PaneContentKind = .git
    private(set) var state: GitPaneState
    var headerAccessories: PaneHeaderAccessories { .specialDefault }
    var matchingKey: String { PaneContent.git(state).matchingKey }
    var headerTitle: String { "git" }
    var headerSubtitle: String? { URL(fileURLWithPath: state.repoPath).lastPathComponent }

    private let service: GitRepositoryService
    private let tableView = NSTableView()
    private let diffView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLeftLabel = NSTextField(labelWithString: "")
    private let footerRightLabel = NSTextField(labelWithString: "")
    private let branchButton = NSButton(title: "branch", target: nil, action: nil)
    private let branchSyncLabel = NSTextField(labelWithString: "")
    private let sourceStageAllButton = GitPaneViewController.iconButton(systemName: "checkmark", tooltip: "Stage all changes")
    private let sourceRefreshButton = GitPaneViewController.iconButton(systemName: "arrow.clockwise", tooltip: "Refresh")
    private let sourceMoreButton = GitPaneViewController.iconButton(systemName: "ellipsis", tooltip: "More source control actions")
    private let selectedBadgeLabel = NSTextField(labelWithString: "M")
    private let selectedDirectoryLabel = NSTextField(labelWithString: "")
    private let selectedFileLabel = NSTextField(labelWithString: "No file selected")
    private let diffLayoutButton = GitPaneViewController.iconButton(systemName: "rectangle.split.2x1", tooltip: "Hide line numbers")
    private let previousChangeButton = GitPaneViewController.iconButton(systemName: "chevron.up", tooltip: "Previous hunk")
    private let nextChangeButton = GitPaneViewController.iconButton(systemName: "chevron.down", tooltip: "Next hunk")
    private let fileActionsButton = GitPaneViewController.iconButton(systemName: "ellipsis", tooltip: "Selected file actions")
    private let additionsLabel = NSTextField(labelWithString: "+0")
    private let deletionsLabel = NSTextField(labelWithString: "-0")
    private let compareButton = NSButton(title: "Compare with HEAD", target: nil, action: nil)

    private var snapshot: GitRepositorySnapshot?
    private var sidebarRows: [GitSidebarRow] = []
    private var collapsedSections: Set<GitSidebarSection> = []
    private var selectedScope: GitDiffScope = .combined
    private var lastRenderedDiff = ""
    private var hunkRanges: [NSRange] = []
    private var showsLineNumbers = true

    init(paneID: Conversation.ID, state: GitPaneState) throws {
        self.paneID = paneID
        self.state = state
        self.service = try GitRepositoryService(repoURL: URL(fileURLWithPath: state.repoPath, isDirectory: true))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = GitPaneDesign.surface.cgColor

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(makeSidebar())
        split.addArrangedSubview(makeDiffArea())
        split.arrangedSubviews.first?.widthAnchor.constraint(equalToConstant: 320).isActive = true

        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        applyTheme()
        refresh()
    }

    func focusContent() {
        view.window?.makeFirstResponder(tableView)
    }

    func applyTheme() {
        view.layer?.backgroundColor = GitPaneDesign.surface.cgColor
        tableView.backgroundColor = GitPaneDesign.surface
        diffView.backgroundColor = GitPaneDesign.surface
        diffView.textColor = GitPaneDesign.text
        statusLabel.textColor = GitPaneDesign.muted
        footerLeftLabel.textColor = GitPaneDesign.muted
        footerRightLabel.textColor = GitPaneDesign.muted
    }

    func updateContent(_ content: PaneContent) {
        guard case .git(let newState) = content else { return }
        let selectedChanged = state.selectedFilePath != newState.selectedFilePath
        let compareChanged = state.compareBase != newState.compareBase
        state = newState
        if selectedChanged || compareChanged {
            refresh()
        }
    }

    func prepareForClose() {}

    private func makeSidebar() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.wantsLayer = true
        container.layer?.backgroundColor = GitPaneDesign.surface.cgColor

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        header.addArrangedSubview(label("SOURCE CONTROL", size: 11, color: GitPaneDesign.muted, weight: .regular))
        header.addArrangedSubview(spacer())
        header.addArrangedSubview(sourceStageAllButton)
        header.addArrangedSubview(sourceRefreshButton)
        header.addArrangedSubview(sourceMoreButton)

        sourceStageAllButton.target = self
        sourceStageAllButton.action = #selector(stageAllTapped)
        sourceRefreshButton.target = self
        sourceRefreshButton.action = #selector(refreshTapped)
        sourceMoreButton.target = self
        sourceMoreButton.action = #selector(sourceMoreTapped)

        let branchRow = NSStackView()
        branchRow.orientation = .horizontal
        branchRow.alignment = .centerY
        branchRow.spacing = 8
        branchRow.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        branchRow.wantsLayer = true
        branchRow.layer?.backgroundColor = GitPaneDesign.chrome.cgColor
        branchRow.addArrangedSubview(symbol("arrow.triangle.branch", color: GitPaneDesign.blue, size: 14))
        branchButton.isBordered = false
        branchButton.bezelStyle = .inline
        branchButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        branchButton.contentTintColor = GitPaneDesign.text
        branchButton.alignment = .left
        branchButton.target = self
        branchButton.action = #selector(branchTapped)
        branchRow.addArrangedSubview(branchButton)
        branchSyncLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        branchSyncLabel.textColor = GitPaneDesign.dim
        branchRow.addArrangedSubview(branchSyncLabel)
        branchRow.addArrangedSubview(spacer())
        branchRow.addArrangedSubview(symbol("chevron.down", color: GitPaneDesign.dim, size: 12))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "Changes"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 25
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = GitPaneDesign.surface
        tableView.selectionHighlightStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = GitPaneDesign.surface

        container.addArrangedSubview(header)
        container.addArrangedSubview(hairline())
        container.addArrangedSubview(branchRow)
        container.addArrangedSubview(hairline())
        container.addArrangedSubview(scroll)
        return container
    }

    private func makeDiffArea() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.wantsLayer = true
        container.layer?.backgroundColor = GitPaneDesign.surface.cgColor

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = GitPaneDesign.chrome.cgColor

        configureSelectedBadge()
        toolbar.addArrangedSubview(selectedBadgeLabel)
        toolbar.addArrangedSubview(selectedDirectoryLabel)
        toolbar.addArrangedSubview(selectedFileLabel)
        toolbar.addArrangedSubview(spacer())
        toolbar.addArrangedSubview(diffLayoutButton)
        toolbar.addArrangedSubview(previousChangeButton)
        toolbar.addArrangedSubview(nextChangeButton)
        toolbar.addArrangedSubview(fileActionsButton)

        diffLayoutButton.target = self
        diffLayoutButton.action = #selector(diffLayoutTapped)
        previousChangeButton.target = self
        previousChangeButton.action = #selector(previousChangeTapped)
        nextChangeButton.target = self
        nextChangeButton.action = #selector(nextChangeTapped)
        fileActionsButton.target = self
        fileActionsButton.action = #selector(fileActionsTapped)

        selectedDirectoryLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        selectedDirectoryLabel.textColor = GitPaneDesign.dim
        selectedDirectoryLabel.lineBreakMode = .byTruncatingMiddle
        selectedFileLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        selectedFileLabel.textColor = GitPaneDesign.text
        selectedFileLabel.lineBreakMode = .byTruncatingTail

        let stats = NSStackView()
        stats.orientation = .horizontal
        stats.alignment = .centerY
        stats.spacing = 12
        stats.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)
        stats.wantsLayer = true
        stats.layer?.backgroundColor = GitPaneDesign.surfaceDeep.cgColor
        additionsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        additionsLabel.textColor = GitPaneDesign.green
        deletionsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        deletionsLabel.textColor = GitPaneDesign.red
        compareButton.isBordered = false
        compareButton.bezelStyle = .inline
        compareButton.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        compareButton.contentTintColor = GitPaneDesign.dim
        compareButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        compareButton.imagePosition = .imageLeading
        compareButton.target = self
        compareButton.action = #selector(compareTapped)
        stats.addArrangedSubview(additionsLabel)
        stats.addArrangedSubview(deletionsLabel)
        stats.addArrangedSubview(spacer())
        stats.addArrangedSubview(compareButton)

        diffView.isEditable = false
        diffView.isRichText = true
        diffView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        diffView.backgroundColor = GitPaneDesign.surface
        diffView.textColor = GitPaneDesign.text
        diffView.textContainerInset = NSSize(width: 14, height: 8)
        diffView.isVerticallyResizable = true
        diffView.isHorizontallyResizable = true
        diffView.autoresizingMask = [.width]
        diffView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffView.textContainer?.widthTracksTextView = false

        let scroll = NSScrollView()
        scroll.documentView = diffView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = GitPaneDesign.surface

        container.addArrangedSubview(toolbar)
        container.addArrangedSubview(stats)
        container.addArrangedSubview(scroll)
        container.addArrangedSubview(makeFooter())
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
        footer.layer?.backgroundColor = GitPaneDesign.chrome.cgColor
        footer.heightAnchor.constraint(equalToConstant: 23).isActive = true
        footerLeftLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        footerRightLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        footer.addArrangedSubview(footerLeftLabel)
        footer.addArrangedSubview(spacer())
        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(footerRightLabel)
        return footer
    }

    @objc private func refreshTapped() {
        refresh()
    }

    @objc private func stageAllTapped() {
        runMutation { try service.stageAll() }
    }

    @objc private func sourceMoreTapped() {
        let menu = NSMenu()
        appendWorktreeItems(to: menu)
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        addMenuItem("Stage All Changes", to: menu, action: #selector(stageAllMenuTapped), enabled: snapshot?.changedFiles.isEmpty == false)
        addMenuItem("Refresh", to: menu, action: #selector(refreshMenuTapped))
        menu.addItem(.separator())
        addMenuItem("Reveal Repository in Finder", to: menu, action: #selector(revealRepositoryTapped))
        addMenuItem("Copy Repository Path", to: menu, action: #selector(copyRepositoryPathTapped))
        pop(menu, from: sourceMoreButton)
    }

    @objc private func stageAllMenuTapped() {
        stageAllTapped()
    }

    @objc private func refreshMenuTapped() {
        refresh()
    }

    @objc private func revealRepositoryTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([service.repoURL])
    }

    @objc private func copyRepositoryPathTapped() {
        copyToPasteboard(service.repoURL.path)
        statusLabel.stringValue = "Copied repository path"
    }

    @objc private func branchTapped() {
        guard let snapshot else { return }
        let menu = NSMenu()
        appendWorktreeItems(to: menu)
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        if snapshot.localBranches.isEmpty {
            addMenuItem("No local branches", to: menu, action: nil, enabled: false)
        } else {
            for branch in snapshot.localBranches {
                let item = NSMenuItem(title: branch, action: #selector(checkoutBranchTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = branch
                item.state = branch == snapshot.branch ? .on : .off
                menu.addItem(item)
            }
        }
        pop(menu, from: branchButton)
    }

    private func appendWorktreeItems(to menu: NSMenu) {
        let worktrees = snapshot?.worktrees.filter { !$0.isBare } ?? []
        guard !worktrees.isEmpty else { return }
        let submenu = NSMenu()
        for worktree in worktrees {
            let title = worktree.isCurrent
                ? "\(worktree.displayName) · \(worktree.displayBranch) ✓"
                : "\(worktree.displayName) · \(worktree.displayBranch)"
            let item = NSMenuItem(title: title, action: #selector(gotoWorktreeTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = worktree.path
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Go to Worktree", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func gotoWorktreeTapped(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if mainWindowController()?.activateWorkspace(projectURL: url) == true {
            return
        }
        do {
            _ = try mainWindowController()?.openGitPane(
                repoURL: url,
                selectedFilePath: nil,
                branch: nil,
                compareBase: nil
            )
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func checkoutBranchTapped(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String else { return }
        runMutation { try service.checkout(branch: branch) }
    }

    @objc private func fileActionsTapped() {
        guard let file = selectedFile() else { return }
        let menu = NSMenu()
        addMenuItem("Stage", to: menu, action: #selector(stageTapped), enabled: file.canStage)
        addMenuItem("Unstage", to: menu, action: #selector(unstageTapped), enabled: file.canUnstage)
        addMenuItem("Discard Changes...", to: menu, action: #selector(discardTapped), enabled: file.canDiscard)
        menu.addItem(.separator())
        addMenuItem("Open in Editor", to: menu, action: #selector(openSelectedInEditorTapped))
        addMenuItem("Reveal in Finder", to: menu, action: #selector(revealSelectedFileTapped))
        addMenuItem("Copy Relative Path", to: menu, action: #selector(copySelectedPathTapped))
        pop(menu, from: fileActionsButton)
    }

    @objc private func stageTapped() {
        guard let file = selectedFile(), file.canStage else { return }
        runMutation { try service.stage(path: file.path) }
    }

    @objc private func unstageTapped() {
        guard let file = selectedFile(), file.canUnstage else { return }
        runMutation { try service.unstage(path: file.path) }
    }

    @objc private func discardTapped() {
        guard let file = selectedFile(), file.canDiscard else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to \(file.path)?"
        alert.informativeText = file.isUntracked
            ? "This deletes the untracked file or folder from disk."
            : "This reverts local unstaged changes in the selected file."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runMutation {
                guard let self else { return }
                try self.service.discard(path: file.path)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    @objc private func openSelectedInEditorTapped() {
        guard let file = selectedFile() else { return }
        let url = service.repoURL.appendingPathComponent(file.path)
        do {
            if isDirectory(url) {
                _ = try mainWindowController()?.openExplorerPane(rootURL: url)
            } else {
                _ = try mainWindowController()?.openEditorPane(fileURL: url, rootURL: service.repoURL, line: nil, column: nil)
            }
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func revealSelectedFileTapped() {
        guard let file = selectedFile() else { return }
        let url = service.repoURL.appendingPathComponent(file.path)
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    @objc private func copySelectedPathTapped() {
        guard let file = selectedFile() else { return }
        copyToPasteboard(file.path)
        statusLabel.stringValue = "Copied \(file.path)"
    }

    @objc private func compareTapped() {
        let menu = NSMenu()
        let head = NSMenuItem(title: "Compare with HEAD", action: #selector(compareModeTapped(_:)), keyEquivalent: "")
        head.target = self
        head.representedObject = ""
        head.state = state.compareBase == nil ? .on : .off
        menu.addItem(head)
        if snapshot?.localBranches.isEmpty == false {
            menu.addItem(.separator())
            snapshot?.localBranches.forEach { branch in
                let item = NSMenuItem(title: "Compare with \(branch)", action: #selector(compareModeTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = branch
                item.state = state.compareBase == branch ? .on : .off
                menu.addItem(item)
            }
        }
        pop(menu, from: compareButton)
    }

    @objc private func compareModeTapped(_ sender: NSMenuItem) {
        let base = sender.representedObject as? String
        state.compareBase = base?.isEmpty == true ? nil : base
        refresh()
        AppEnvironment.conversationStore?.updateContent(paneID, content: .git(state), workingDirectoryPath: state.repoPath)
    }

    @objc private func diffLayoutTapped() {
        showsLineNumbers.toggle()
        diffLayoutButton.toolTip = showsLineNumbers ? "Hide line numbers" : "Show line numbers"
        renderDiff(lastRenderedDiff)
    }

    @objc private func previousChangeTapped() {
        navigateHunk(delta: -1)
    }

    @objc private func nextChangeTapped() {
        navigateHunk(delta: 1)
    }

    private func runMutation(_ body: () throws -> Void) {
        do {
            try body()
            refresh()
        } catch {
            statusLabel.stringValue = error.localizedDescription.isEmpty ? "Git command failed" : error.localizedDescription
        }
    }

    private func refresh() {
        do {
            let snapshot = try service.snapshot()
            self.snapshot = snapshot
            rebuildSidebarRows(snapshot)
            tableView.reloadData()
            updateBranchChrome(snapshot)
            footerLeftLabel.stringValue = service.currentHeadSummary() ?? snapshot.branch
            footerRightLabel.stringValue = state.compareBase.map { "Diff: \($0)   UTF-8" } ?? "Diff: unified   LF   UTF-8"
            statusLabel.stringValue = "\(snapshot.changedFiles.count) changes"

            if let selected = state.selectedFilePath,
               let row = firstFileRow(matching: selected, preferredScope: selectedScope) {
                selectAndLoad(row: row)
            } else if let first = firstFileRow() {
                selectAndLoad(row: first)
            } else {
                updateSelectedFileHeader(nil, section: nil)
                renderDiff("Working tree clean.")
            }
            updateActionButtons()
        } catch {
            statusLabel.stringValue = error.localizedDescription
            updateSelectedFileHeader(nil, section: nil)
            renderDiff(error.localizedDescription)
        }
    }

    private func rebuildSidebarRows(_ snapshot: GitRepositorySnapshot) {
        sidebarRows = GitSidebarSection.allCases.flatMap { section -> [GitSidebarRow] in
            let files = section.files(in: snapshot)
            guard !files.isEmpty else { return [] }
            var rows: [GitSidebarRow] = [.section(section, count: files.count)]
            if !collapsedSections.contains(section) {
                rows.append(contentsOf: files.map { .file($0, section) })
            }
            return rows
        }
    }

    private func selectAndLoad(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard case .file(let file, let section) = sidebarRows[row] else { return }
        loadDiff(file: file, section: section)
    }

    private func loadDiff(file: GitChangedFile?, section: GitSidebarSection?) {
        do {
            let scope = section?.scope ?? .combined
            selectedScope = scope
            updateSelectedFileHeader(file, section: section)
            renderDiff(try service.diff(path: file?.path, compareBase: state.compareBase, scope: scope))
            if let file {
                state.selectedFilePath = file.path
                AppEnvironment.conversationStore?.updateContent(paneID, content: .git(state), workingDirectoryPath: state.repoPath)
            }
            updateActionButtons()
        } catch {
            renderDiff(error.localizedDescription)
        }
    }

    private func renderDiff(_ diff: String) {
        lastRenderedDiff = diff
        hunkRanges.removeAll()

        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.lineBreakMode = .byClipping
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: GitPaneDesign.text,
            .paragraphStyle: paragraph,
        ]

        var oldLine: Int?
        var newLine: Int?
        diff.enumerateLines { line, _ in
            var attrs = baseAttrs
            var prefix: String?
            let displayLine = line

            if line.hasPrefix("@@") {
                let rangeStart = output.length
                if let hunk = self.parseHunkHeader(line) {
                    oldLine = hunk.oldStart
                    newLine = hunk.newStart
                }
                attrs[.foregroundColor] = GitPaneDesign.hunkBlue
                attrs[.backgroundColor] = GitPaneDesign.hunkBackground
                self.hunkRanges.append(NSRange(location: rangeStart, length: (line as NSString).length))
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                prefix = self.lineNumberPrefix(old: nil, new: newLine)
                newLine = newLine.map { $0 + 1 }
                attrs[.foregroundColor] = GitPaneDesign.greenText
                attrs[.backgroundColor] = GitPaneDesign.greenBackground
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                prefix = self.lineNumberPrefix(old: oldLine, new: nil)
                oldLine = oldLine.map { $0 + 1 }
                attrs[.foregroundColor] = GitPaneDesign.redText
                attrs[.backgroundColor] = GitPaneDesign.redBackground
            } else if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
                attrs[.foregroundColor] = GitPaneDesign.yellow
            } else if oldLine != nil || newLine != nil {
                prefix = self.lineNumberPrefix(old: oldLine, new: newLine)
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    attrs[.foregroundColor] = GitPaneDesign.dim
                }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                attrs[.foregroundColor] = GitPaneDesign.dim
            }

            if !self.showsLineNumbers {
                prefix = nil
            }

            if let prefix {
                var prefixAttrs = attrs
                prefixAttrs[.foregroundColor] = GitPaneDesign.dim
                output.append(NSAttributedString(string: prefix, attributes: prefixAttrs))
            }
            output.append(NSAttributedString(string: displayLine + "\n", attributes: attrs))
        }

        diffView.textStorage?.setAttributedString(output)
        let stats = diffStats(for: diff)
        additionsLabel.stringValue = "+\(stats.additions)"
        deletionsLabel.stringValue = "-\(stats.deletions)"
        updateHunkButtons()
    }

    private func diffStats(for diff: String) -> GitDiffStats {
        var stats = GitDiffStats.empty
        diff.enumerateLines { line, _ in
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                stats.additions += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                stats.deletions += 1
            }
        }
        return stats
    }

    private func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let parts = line.split(separator: " ")
        guard let oldToken = parts.first(where: { $0.hasPrefix("-") }),
              let newToken = parts.first(where: { $0.hasPrefix("+") }) else { return nil }
        let oldStart = oldToken.dropFirst().split(separator: ",").first.flatMap { Int($0) }
        let newStart = newToken.dropFirst().split(separator: ",").first.flatMap { Int($0) }
        guard let oldStart, let newStart else { return nil }
        return (oldStart, newStart)
    }

    private func lineNumberPrefix(old: Int?, new: Int?) -> String {
        "\(padded(old.map(String.init) ?? "")) \(padded(new.map(String.init) ?? ""))  "
    }

    private func padded(_ string: String) -> String {
        String(repeating: " ", count: max(0, 4 - string.count)) + string
    }

    private func selectedFile() -> GitChangedFile? {
        guard tableView.selectedRow >= 0,
              tableView.selectedRow < sidebarRows.count,
              case .file(let file, _) = sidebarRows[tableView.selectedRow] else { return nil }
        return file
    }

    private func selectedFileAndSection() -> (file: GitChangedFile, section: GitSidebarSection)? {
        guard tableView.selectedRow >= 0,
              tableView.selectedRow < sidebarRows.count,
              case .file(let file, let section) = sidebarRows[tableView.selectedRow] else { return nil }
        return (file, section)
    }

    private func firstFileRow(matching path: String? = nil, preferredScope: GitDiffScope? = nil) -> Int? {
        if let path, let preferredScope {
            for (index, row) in sidebarRows.enumerated() {
                if case .file(let file, let section) = row, file.path == path, section.scope == preferredScope {
                    return index
                }
            }
        }
        if let path {
            for (index, row) in sidebarRows.enumerated() {
                if case .file(let file, _) = row, file.path == path {
                    return index
                }
            }
        }
        for (index, row) in sidebarRows.enumerated() {
            if case .file = row { return index }
        }
        return nil
    }

    private func updateActionButtons() {
        let hasChanges = snapshot?.changedFiles.isEmpty == false
        sourceStageAllButton.isEnabled = hasChanges
        sourceMoreButton.isEnabled = true
        fileActionsButton.isEnabled = selectedFile() != nil
        compareButton.title = state.compareBase.map { "Compare with \($0)" } ?? "Compare with HEAD"
        updateHunkButtons()
    }

    private func updateHunkButtons() {
        previousChangeButton.isEnabled = !hunkRanges.isEmpty
        nextChangeButton.isEnabled = !hunkRanges.isEmpty
    }

    private func updateBranchChrome(_ snapshot: GitRepositorySnapshot) {
        branchButton.title = snapshot.branch
        branchSyncLabel.stringValue = snapshot.branchSyncSummary
    }

    private func updateSelectedFileHeader(_ file: GitChangedFile?, section: GitSidebarSection?) {
        guard let file else {
            selectedBadgeLabel.stringValue = " "
            selectedBadgeLabel.isHidden = true
            selectedDirectoryLabel.stringValue = ""
            selectedFileLabel.stringValue = "No file selected"
            selectedFileLabel.textColor = GitPaneDesign.dim
            return
        }

        selectedBadgeLabel.isHidden = false
        selectedBadgeLabel.stringValue = file.badgeText(preferStaged: section?.preferStagedBadge == true)
        selectedBadgeLabel.textColor = statusColor(for: file, section: section)
        selectedDirectoryLabel.stringValue = file.parentDisplayPath == "/" ? "" : "\(file.parentDisplayPath)/"
        selectedFileLabel.stringValue = file.displayName
        selectedFileLabel.textColor = GitPaneDesign.text
    }

    private func navigateHunk(delta: Int) {
        guard !hunkRanges.isEmpty else { return }
        let selectedLocation = diffView.selectedRange().location
        let current = hunkRanges.lastIndex { $0.location <= selectedLocation } ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(hunkRanges.count - 1, current + delta))
        let range = hunkRanges[next]
        diffView.setSelectedRange(range)
        diffView.scrollRangeToVisible(range)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sidebarRows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < sidebarRows.count else { return 25 }
        if case .section = sidebarRows[row] { return 28 }
        return 25
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < sidebarRows.count else { return false }
        if case .section(let section, _) = sidebarRows[row] {
            if collapsedSections.contains(section) {
                collapsedSections.remove(section)
            } else {
                collapsedSections.insert(section)
            }
            if let snapshot {
                rebuildSidebarRows(snapshot)
                tableView.reloadData()
            }
            return false
        }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sidebarRows.count else { return nil }
        switch sidebarRows[row] {
        case .section(let section, let count):
            return sectionCell(section: section, count: count)
        case .file(let file, let section):
            return fileCell(file: file, section: section)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let selection = selectedFileAndSection() else { return }
        loadDiff(file: selection.file, section: selection.section)
    }

    private func sectionCell(section: GitSidebarSection, count: Int) -> NSView {
        let cell = NSTableCellView()
        let rowView = NSStackView()
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 6
        rowView.translatesAutoresizingMaskIntoConstraints = false
        let chevron = collapsedSections.contains(section) ? "chevron.right" : "chevron.down"
        rowView.addArrangedSubview(symbol(chevron, color: GitPaneDesign.muted, size: 12))
        rowView.addArrangedSubview(label(section.title, size: 10, color: GitPaneDesign.text, weight: .bold))
        rowView.addArrangedSubview(spacer())
        rowView.addArrangedSubview(countBadge(count))
        cell.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            rowView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func fileCell(file: GitChangedFile, section: GitSidebarSection) -> NSView {
        let cell = NSTableCellView()
        let rowView = NSStackView()
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 6
        rowView.translatesAutoresizingMaskIntoConstraints = false
        let nameLabel = label(file.displayName, size: 11, color: textColor(for: file), weight: .regular)
        let parentLabel = label(file.parentDisplayPath, size: 10, color: GitPaneDesign.dim, weight: .regular)
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowView.addArrangedSubview(nameLabel)
        rowView.addArrangedSubview(parentLabel)
        rowView.addArrangedSubview(spacer())
        rowView.addArrangedSubview(statusGlyph(file, section: section))
        cell.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            rowView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func statusGlyph(_ file: GitChangedFile, section: GitSidebarSection) -> NSTextField {
        let glyph = label(file.badgeText(preferStaged: section.preferStagedBadge), size: 11, color: statusColor(for: file, section: section), weight: .bold)
        glyph.alignment = .center
        glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return glyph
    }

    private func statusColor(for file: GitChangedFile, section: GitSidebarSection?) -> NSColor {
        if file.isConflicted { return GitPaneDesign.red }
        if file.isUntracked { return GitPaneDesign.blue }
        if section == .staged { return GitPaneDesign.green }
        if file.badgeText(preferStaged: section?.preferStagedBadge == true) == "D" { return GitPaneDesign.red }
        return GitPaneDesign.yellow
    }

    private func textColor(for file: GitChangedFile) -> NSColor {
        if file.isConflicted { return GitPaneDesign.redText }
        if file.isUntracked { return GitPaneDesign.blue }
        return GitPaneDesign.text
    }

    private func configureSelectedBadge() {
        selectedBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        selectedBadgeLabel.alignment = .center
        selectedBadgeLabel.wantsLayer = true
        selectedBadgeLabel.layer?.backgroundColor = GitPaneDesign.badgeBackground.cgColor
        selectedBadgeLabel.layer?.cornerRadius = 3
        selectedBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        selectedBadgeLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    private func countBadge(_ count: Int) -> NSTextField {
        let badge = label("\(count)", size: 9, color: GitPaneDesign.text, weight: .medium)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = GitPaneDesign.badgeBackground.cgColor
        badge.layer?.cornerRadius = 8
        badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return badge
    }

    private func addMenuItem(_ title: String, to menu: NSMenu, action: Selector?, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func pop(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func mainWindowController() -> SoyehtMainWindowController? {
        view.window?.windowController as? SoyehtMainWindowController
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func hairline() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = GitPaneDesign.border.cgColor
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

    private static func iconButton(systemName: String, tooltip: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip)
        button.contentTintColor = GitPaneDesign.muted
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }
}
