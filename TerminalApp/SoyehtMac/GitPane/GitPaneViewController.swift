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
    static let muted = NSColor(soyehtRequiredHex: "#8A92A5")
    static let dim = NSColor(soyehtRequiredHex: "#555B6E")
    static let blue = NSColor(soyehtRequiredHex: "#5B9CF6")
    static let yellow = NSColor(soyehtRequiredHex: "#FFD66B")
    static let green = NSColor(soyehtRequiredHex: "#98C379")
    static let greenText = NSColor(soyehtRequiredHex: "#A5D6A7")
    static let greenBackground = NSColor(soyehtRequiredHex: "#1F3A26")
    static let red = NSColor(soyehtRequiredHex: "#E06C75")
    static let redText = NSColor(soyehtRequiredHex: "#E5989B")
    static let redBackground = NSColor(soyehtRequiredHex: "#3A1F22")
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
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let stageButton = NSButton(title: "Stage", target: nil, action: nil)
    private let unstageButton = NSButton(title: "Unstage", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private let compareButton = NSButton(title: "Compare main", target: nil, action: nil)
    private var snapshot: GitRepositorySnapshot?
    private var selectedState: GitChangedFile.State?

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
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        header.addArrangedSubview(label("SOURCE CONTROL", size: 11, color: GitPaneDesign.muted, weight: .regular))
        header.addArrangedSubview(spacer())
        header.addArrangedSubview(symbol("arrow.triangle.branch", color: GitPaneDesign.muted, size: 12))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "Changes"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
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
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = GitPaneDesign.chrome.cgColor
        toolbar.heightAnchor.constraint(equalToConstant: 33).isActive = true

        [refreshButton, stageButton, unstageButton, discardButton, compareButton].forEach {
            $0.bezelStyle = .inline
            $0.controlSize = .small
            $0.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            toolbar.addArrangedSubview($0)
        }
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        stageButton.target = self
        stageButton.action = #selector(stageTapped)
        unstageButton.target = self
        unstageButton.action = #selector(unstageTapped)
        discardButton.target = self
        discardButton.action = #selector(discardTapped)
        compareButton.target = self
        compareButton.action = #selector(compareTapped)
        toolbar.addArrangedSubview(spacer())
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        toolbar.addArrangedSubview(statusLabel)

        diffView.isEditable = false
        diffView.isRichText = true
        diffView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        diffView.backgroundColor = GitPaneDesign.surface
        diffView.textColor = GitPaneDesign.text
        diffView.textContainerInset = NSSize(width: 14, height: 10)
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
        footer.addArrangedSubview(footerLeftLabel)
        footer.addArrangedSubview(spacer())
        footer.addArrangedSubview(footerRightLabel)
        return footer
    }

    @objc private func refreshTapped() {
        refresh()
    }

    @objc private func stageTapped() {
        guard let file = selectedFile() else { return }
        runMutation { try service.stage(path: file.path) }
    }

    @objc private func unstageTapped() {
        guard let file = selectedFile() else { return }
        runMutation { try service.unstage(path: file.path) }
    }

    @objc private func discardTapped() {
        guard let file = selectedFile() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to \(file.path)?"
        alert.informativeText = file.state == .untracked
            ? "This deletes the untracked file from disk."
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

    @objc private func compareTapped() {
        state.compareBase = state.compareBase == nil ? "main" : nil
        compareButton.title = state.compareBase == nil ? "Compare main" : "Working tree"
        refresh()
        AppEnvironment.conversationStore?.updateContent(paneID, content: .git(state), workingDirectoryPath: state.repoPath)
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
            tableView.reloadData()
            statusLabel.stringValue = "\(snapshot.branch) · \(snapshot.changedFiles.count) changes"
            footerLeftLabel.stringValue = service.currentHeadSummary() ?? snapshot.branch
            footerRightLabel.stringValue = state.compareBase.map { "Diff: \($0)   UTF-8" } ?? "Diff: unified   LF   UTF-8"
            if let selected = state.selectedFilePath,
               let row = snapshot.changedFiles.firstIndex(where: { $0.path == selected }) {
                selectAndLoad(row: row, file: snapshot.changedFiles[row])
            } else if let first = snapshot.changedFiles.first {
                selectAndLoad(row: 0, file: first)
            } else {
                selectedState = nil
                renderDiff("Working tree clean.")
            }
            updateActionButtons()
        } catch {
            statusLabel.stringValue = error.localizedDescription
            renderDiff(error.localizedDescription)
        }
    }

    private func selectAndLoad(row: Int, file: GitChangedFile) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        loadDiff(file: file)
    }

    private func loadDiff(file: GitChangedFile?) {
        do {
            selectedState = file?.state
            renderDiff(try service.diff(path: file?.path, compareBase: state.compareBase))
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
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: GitPaneDesign.text,
            .paragraphStyle: paragraph,
        ]
        diff.enumerateLines { line, _ in
            var attrs = baseAttrs
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                attrs[.foregroundColor] = GitPaneDesign.greenText
                attrs[.backgroundColor] = GitPaneDesign.greenBackground
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                attrs[.foregroundColor] = GitPaneDesign.redText
                attrs[.backgroundColor] = GitPaneDesign.redBackground
            } else if line.hasPrefix("@@") {
                attrs[.foregroundColor] = GitPaneDesign.blue
            } else if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
                attrs[.foregroundColor] = GitPaneDesign.yellow
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                attrs[.foregroundColor] = GitPaneDesign.dim
            }
            output.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        diffView.textStorage?.setAttributedString(output)
    }

    private func selectedFile() -> GitChangedFile? {
        guard let snapshot,
              tableView.selectedRow >= 0,
              tableView.selectedRow < snapshot.changedFiles.count else { return nil }
        return snapshot.changedFiles[tableView.selectedRow]
    }

    private func updateActionButtons() {
        guard let file = selectedFile() else {
            stageButton.isEnabled = false
            unstageButton.isEnabled = false
            discardButton.isEnabled = false
            return
        }
        stageButton.isEnabled = file.state == .unstaged || file.state == .untracked || file.state == .conflicted
        unstageButton.isEnabled = file.state == .staged
        discardButton.isEnabled = file.state == .unstaged || file.state == .untracked
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshot?.changedFiles.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let file = snapshot?.changedFiles[row] else { return nil }
        let cell = NSTableCellView()
        let rowView = NSStackView()
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 6
        rowView.translatesAutoresizingMaskIntoConstraints = false
        rowView.addArrangedSubview(stateBadge(file.state))
        rowView.addArrangedSubview(label(file.path, size: 11, color: textColor(for: file.state), weight: .regular))
        cell.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            rowView.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadDiff(file: selectedFile())
    }

    private func stateBadge(_ state: GitChangedFile.State) -> NSTextField {
        let text: String
        let color: NSColor
        switch state {
        case .staged:
            text = "S"
            color = GitPaneDesign.green
        case .unstaged:
            text = "M"
            color = GitPaneDesign.yellow
        case .untracked:
            text = "U"
            color = GitPaneDesign.blue
        case .conflicted:
            text = "!"
            color = GitPaneDesign.red
        }
        let badge = label(text, size: 10, color: color, weight: .bold)
        badge.alignment = .center
        badge.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return badge
    }

    private func textColor(for state: GitChangedFile.State) -> NSColor {
        switch state {
        case .conflicted: return GitPaneDesign.redText
        case .untracked: return GitPaneDesign.blue
        default: return GitPaneDesign.text
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
}
