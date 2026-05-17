import AppKit

/// Spotlight-style fuzzy file finder scoped to the editor pane's root.
/// Mirrors `CommandPaletteWindowController` chrome so both palettes feel like
/// the same surface.
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("EditorFileFinderRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? EditorFileFinderRowView)
            ?? {
                let view = EditorFileFinderRowView()
                view.identifier = identifier
                return view
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
