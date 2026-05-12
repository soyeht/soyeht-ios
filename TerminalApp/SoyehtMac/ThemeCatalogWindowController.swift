import Cocoa
import SoyehtCore

final class ThemeCatalogWindowController: NSWindowController {
    init(onInstall: @escaping (TerminalColorTheme) -> Void) {
        let contentVC = ThemeCatalogViewController(onInstall: onInstall)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "themeCatalog.window.title")
        window.contentViewController = contentVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ThemeCatalogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let catalog = TerminalThemeCatalog.iTerm2ColorSchemes
    private let client = TerminalThemeCatalogClient(catalog: .iTerm2ColorSchemes)
    private let onInstall: (TerminalColorTheme) -> Void

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let installButton = NSButton(title: String(localized: "themeCatalog.button.install"), target: nil, action: nil)
    private let refreshButton = NSButton(title: String(localized: "themeCatalog.button.refresh"), target: nil, action: nil)

    private var items: [TerminalThemeCatalogItem] = []
    private var filteredItems: [TerminalThemeCatalogItem] = []
    private var loadTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

    init(onInstall: @escaping (TerminalColorTheme) -> Void) {
        self.onInstall = onInstall
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        loadTask?.cancel()
        installTask?.cancel()
    }

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 560, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        loadCatalog()
    }

    private func buildUI() {
        [searchField, scrollView, statusLabel, progress, refreshButton, installButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        searchField.placeholderString = String(
            localized: "themeCatalog.search.placeholder",
            defaultValue: "Search \(catalog.displayName)",
            comment: "Theme catalog search placeholder. %@ = catalog display name."
        )
        searchField.delegate = self

        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 28

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
        column.title = String(localized: "themeCatalog.column.theme")
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshCatalog)

        installButton.target = self
        installButton.action = #selector(installSelectedTheme)
        installButton.keyEquivalent = "\r"
        installButton.isEnabled = false

        let cancelButton = NSButton(title: String(localized: "common.button.cancel"), target: self, action: #selector(cancel))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progress.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),

            refreshButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),

            cancelButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: installButton.leadingAnchor, constant: -8),

            installButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            installButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    @objc private func refreshCatalog() {
        loadCatalog()
    }

    private func loadCatalog() {
        loadTask?.cancel()
        setLoading(true, message: String(
            localized: "themeCatalog.status.loading",
            defaultValue: "Loading \(catalog.displayName)...",
            comment: "Status while loading a theme catalog. %@ = catalog display name."
        ))
        items = []
        applyFilter()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await client.fetchItems()
                await MainActor.run {
                    self.items = fetched
                    self.applyFilter()
                    self.setLoading(false, message: String(
                        localized: "themeCatalog.status.loaded",
                        defaultValue: "\(fetched.count) themes available from \(self.catalog.displayName).",
                        comment: "Status after loading a theme catalog. %lld = theme count, %@ = catalog display name."
                    ))
                }
            } catch {
                await MainActor.run {
                    self.setLoading(false, message: String(localized: "themeCatalog.status.loadFailed"))
                    self.showError(error)
                }
            }
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredItems = items
        } else {
            filteredItems = items.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateInstallButton()
    }

    private func setLoading(_ loading: Bool, message: String) {
        statusLabel.stringValue = message
        refreshButton.isEnabled = !loading
        installButton.isEnabled = !loading && selectedItem() != nil
        loading ? progress.startAnimation(nil) : progress.stopAnimation(nil)
    }

    @objc private func installSelectedTheme() {
        guard let item = selectedItem() else { return }
        installTask?.cancel()
        setLoading(true, message: String(
            localized: "themeCatalog.status.installing",
            defaultValue: "Installing \(item.displayName)...",
            comment: "Status while installing a theme. %@ = theme display name."
        ))

        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await client.install(item)
                await MainActor.run {
                    self.onInstall(saved)
                    self.closeBrowser()
                }
            } catch {
                await MainActor.run {
                    self.setLoading(false, message: String(
                        localized: "themeCatalog.status.installFailed",
                        defaultValue: "Could not install \(item.displayName).",
                        comment: "Status shown when theme installation fails. %@ = theme display name."
                    ))
                    self.showError(error)
                }
            }
        }
    }

    @objc private func cancel() {
        closeBrowser()
    }

    private func selectedItem() -> TerminalThemeCatalogItem? {
        let row = tableView.selectedRow
        guard filteredItems.indices.contains(row) else { return nil }
        return filteredItems[row]
    }

    private func updateInstallButton() {
        installButton.isEnabled = selectedItem() != nil
    }

    private func closeBrowser() {
        guard let window = view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateInstallButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredItems.indices.contains(row) else { return nil }
        let item = filteredItems[row]
        let identifier = NSUserInterfaceItemIdentifier("ThemeCatalogCell")

        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.stringValue = item.displayName
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: item.displayName)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
