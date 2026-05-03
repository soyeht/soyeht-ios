//
//  PreferencesWindowController.swift
//  Soyeht
//
//  Cmd+, preferences: font size stepper + color theme picker.
//  Changes apply immediately to all open terminal tabs via NotificationCenter.
//

import Cocoa
import SoyehtCore

extension Notification.Name {
    static let preferencesDidChange = Notification.Name("SoyehtPreferencesDidChange")
}

class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private init() {
        let contentVC = PreferencesViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "prefs.window.title", comment: "Title of the Preferences window.")
        window.contentViewController = contentVC
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use PreferencesWindowController.shared") }
}

// MARK: -

class PreferencesViewController: NSViewController {

    private let prefs = TerminalPreferences.shared

    private let fontSizeLabel = NSTextField(labelWithString: String(localized: "prefs.label.fontSize", comment: "Preferences row label for terminal font size."))
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()

    private let themeLabel = NSTextField(labelWithString: String(localized: "prefs.label.colorTheme", comment: "Preferences row label for the color theme picker."))
    private let themePopUp = NSPopUpButton()
    private let browseCatalogButton = NSButton(title: "Browse Catalog...", target: nil, action: nil)
    private let importThemeButton = NSButton(title: "Import...", target: nil, action: nil)
    private let installThemeURLButton = NSButton(title: "Install from URL...", target: nil, action: nil)
    private let customizeThemeButton = NSButton(title: "Customize...", target: nil, action: nil)
    private let deleteThemeButton = NSButton(title: "Delete", target: nil, action: nil)

    private let displayNameLabel = NSTextField(labelWithString: String(localized: "prefs.label.displayName", comment: "Preferences row label for the Mac's display name shown on paired iPhones."))
    private let displayNameField = NSTextField()

    private let automaticallyCheckForUpdatesButton = NSButton(
        checkboxWithTitle: String(localized: "prefs.checkbox.automaticallyCheckForUpdates", comment: "Preferences checkbox that enables automatic update checks."),
        target: nil,
        action: nil
    )
    private var themes: [TerminalColorTheme] = []
    private var themeEditor: ThemeEditorWindowController?
    private var themeCatalogBrowser: ThemeCatalogWindowController?

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 660, height: 350))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        populateThemes()
        loadCurrentValues()
    }

    private func buildUI() {
        [
            fontSizeLabel, fontSizeField, fontSizeStepper,
            themeLabel, themePopUp, browseCatalogButton, importThemeButton, installThemeURLButton, customizeThemeButton, deleteThemeButton,
            displayNameLabel, displayNameField, automaticallyCheckForUpdatesButton
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        displayNameLabel.alignment = .right
        displayNameField.isEditable = true
        displayNameField.isBezeled = true
        displayNameField.bezelStyle = .squareBezel
        displayNameField.placeholderString = Host.current().localizedName ?? "Mac"
        displayNameField.target = self
        displayNameField.action = #selector(displayNameChanged)

        fontSizeLabel.alignment = .right
        fontSizeField.isEditable = true
        fontSizeField.isBezeled = true
        fontSizeField.bezelStyle = .squareBezel
        fontSizeField.delegate = self

        fontSizeStepper.minValue = Double(TerminalPreferences.minimumFontSize)
        fontSizeStepper.maxValue = 32
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(stepperChanged)

        themeLabel.alignment = .right

        themePopUp.target = self
        themePopUp.action = #selector(themeChanged)

        browseCatalogButton.target = self
        browseCatalogButton.action = #selector(browseThemeCatalog)
        importThemeButton.target = self
        importThemeButton.action = #selector(importThemeFromFile)
        installThemeURLButton.target = self
        installThemeURLButton.action = #selector(installThemeFromURL)
        customizeThemeButton.target = self
        customizeThemeButton.action = #selector(customizeTheme)
        deleteThemeButton.target = self
        deleteThemeButton.action = #selector(deleteTheme)

        automaticallyCheckForUpdatesButton.target = self
        automaticallyCheckForUpdatesButton.action = #selector(automaticallyCheckForUpdatesChanged)
        automaticallyCheckForUpdatesButton.isEnabled = SoyehtUpdater.shared.isConfigured

        let labelWidth: CGFloat = 100

        NSLayoutConstraint.activate([
            fontSizeLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            fontSizeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            fontSizeLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            fontSizeField.centerYAnchor.constraint(equalTo: fontSizeLabel.centerYAnchor),
            fontSizeField.leadingAnchor.constraint(equalTo: fontSizeLabel.trailingAnchor, constant: 8),
            fontSizeField.widthAnchor.constraint(equalToConstant: 50),

            fontSizeStepper.centerYAnchor.constraint(equalTo: fontSizeField.centerYAnchor),
            fontSizeStepper.leadingAnchor.constraint(equalTo: fontSizeField.trailingAnchor, constant: 4),

            themeLabel.topAnchor.constraint(equalTo: fontSizeLabel.bottomAnchor, constant: 20),
            themeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            themeLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            themePopUp.centerYAnchor.constraint(equalTo: themeLabel.centerYAnchor),
            themePopUp.leadingAnchor.constraint(equalTo: themeLabel.trailingAnchor, constant: 8),
            themePopUp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            browseCatalogButton.topAnchor.constraint(equalTo: themePopUp.bottomAnchor, constant: 8),
            browseCatalogButton.leadingAnchor.constraint(equalTo: themePopUp.leadingAnchor),

            importThemeButton.centerYAnchor.constraint(equalTo: browseCatalogButton.centerYAnchor),
            importThemeButton.leadingAnchor.constraint(equalTo: browseCatalogButton.trailingAnchor, constant: 8),

            installThemeURLButton.centerYAnchor.constraint(equalTo: browseCatalogButton.centerYAnchor),
            installThemeURLButton.leadingAnchor.constraint(equalTo: importThemeButton.trailingAnchor, constant: 8),

            customizeThemeButton.centerYAnchor.constraint(equalTo: browseCatalogButton.centerYAnchor),
            customizeThemeButton.leadingAnchor.constraint(equalTo: installThemeURLButton.trailingAnchor, constant: 8),

            deleteThemeButton.centerYAnchor.constraint(equalTo: browseCatalogButton.centerYAnchor),
            deleteThemeButton.leadingAnchor.constraint(equalTo: customizeThemeButton.trailingAnchor, constant: 8),
            deleteThemeButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            displayNameLabel.topAnchor.constraint(equalTo: browseCatalogButton.bottomAnchor, constant: 22),
            displayNameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            displayNameLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            displayNameField.centerYAnchor.constraint(equalTo: displayNameLabel.centerYAnchor),
            displayNameField.leadingAnchor.constraint(equalTo: displayNameLabel.trailingAnchor, constant: 8),
            displayNameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            automaticallyCheckForUpdatesButton.topAnchor.constraint(equalTo: displayNameLabel.bottomAnchor, constant: 20),
            automaticallyCheckForUpdatesButton.leadingAnchor.constraint(equalTo: displayNameField.leadingAnchor),
            automaticallyCheckForUpdatesButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func populateThemes() {
        themePopUp.removeAllItems()
        themes = TerminalThemeStore.shared.allThemes()
        for theme in themes {
            themePopUp.addItem(withTitle: themeMenuTitle(theme))
            themePopUp.lastItem?.representedObject = theme
        }
        updateDeleteButton()
    }

    private func loadCurrentValues() {
        fontSizeStepper.doubleValue = Double(prefs.fontSize)
        fontSizeField.stringValue = String(Int(prefs.fontSize))

        let currentTheme = TerminalColorTheme.active
        for (idx, item) in themePopUp.itemArray.enumerated() {
            if let theme = item.representedObject as? TerminalColorTheme, theme.id == currentTheme.id {
                themePopUp.selectItem(at: idx)
                break
            }
        }
        updateDeleteButton()

        // Show the override (if any) so the user sees what's currently being
        // advertised to paired iPhones. Placeholder shows the hostname so
        // "clear = fall back" is discoverable.
        if let override = UserDefaults.standard.string(forKey: "com.soyeht.mac.macDisplayName"),
           !override.isEmpty {
            displayNameField.stringValue = override
        }

        automaticallyCheckForUpdatesButton.state = SoyehtUpdater.shared.automaticallyChecksForUpdates ? .on : .off
    }

    @objc private func displayNameChanged() {
        let value = displayNameField.stringValue
        PairingStore.shared.setMacDisplayName(value)
        // Broadcast so every connected iPhone refreshes its label immediately
        // without waiting for the next list_panes.
        let payload: [String: Any] = [
            "updated": [[
                "display_name": PairingStore.shared.macName,
            ]]
        ]
        PairingPresenceServer.shared.broadcastPanesDelta(payload)
    }

    @objc private func stepperChanged() {
        let size = CGFloat(fontSizeStepper.doubleValue)
        fontSizeField.stringValue = String(Int(size))
        applyFontSize(size)
    }

    @objc private func themeChanged() {
        guard let theme = themePopUp.selectedItem?.representedObject as? TerminalColorTheme else { return }
        TerminalThemeStore.shared.setActiveTheme(id: theme.id)
        prefs.cursorColorHex = theme.cursorHex
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        updateDeleteButton()
    }

    @objc private func importThemeFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Terminal Theme"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["itermcolors", "conf", "theme", "txt"]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.installTheme(from: url)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func browseThemeCatalog() {
        let browser = ThemeCatalogWindowController { [weak self] saved in
            self?.selectAndApplyTheme(saved)
        }
        themeCatalogBrowser = browser

        guard let browserWindow = browser.window else { return }
        if let window = view.window {
            window.beginSheet(browserWindow) { [weak self] _ in
                self?.themeCatalogBrowser = nil
            }
        } else {
            browser.showWindow(self)
        }
    }

    @objc private func installThemeFromURL() {
        let alert = NSAlert()
        alert.messageText = "Install Theme from URL"
        alert.informativeText = "Paste a raw Ghostty theme or .itermcolors URL."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "https://raw.githubusercontent.com/..."
        alert.accessoryView = field

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return
            }
            self?.downloadAndInstallTheme(from: url)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    @objc private func customizeTheme() {
        guard let theme = selectedTheme() else { return }
        let replacingID = theme.source == .builtIn ? nil : theme.id
        let editor = ThemeEditorWindowController(theme: theme, replacingID: replacingID) { [weak self] saved in
            self?.selectAndApplyTheme(saved)
        }
        themeEditor = editor
        guard let editorWindow = editor.window else { return }
        if let window = view.window {
            window.beginSheet(editorWindow) { [weak self] _ in
                self?.themeEditor = nil
            }
        } else {
            editor.showWindow(self)
        }
    }

    @objc private func deleteTheme() {
        guard let theme = selectedTheme(), theme.source != .builtIn else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Theme?"
        alert.informativeText = "This removes \(theme.displayName) from Soyeht."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try TerminalThemeStore.shared.deleteUserTheme(id: theme.id)
                self?.selectAndApplyTheme(TerminalColorTheme.active)
            } catch {
                self?.showError(error)
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    @objc private func automaticallyCheckForUpdatesChanged() {
        SoyehtUpdater.shared.automaticallyChecksForUpdates = automaticallyCheckForUpdatesButton.state == .on
    }

    private func applyFontSize(_ size: CGFloat) {
        prefs.fontSize = size
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }

    private func installTheme(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let imported = try TerminalThemeImporter.importTheme(
                data: data,
                filename: url.lastPathComponent,
                sourceURL: url.absoluteString
            )
            let saved = try TerminalThemeStore.shared.saveImportedTheme(imported)
            selectAndApplyTheme(saved)
        } catch {
            showError(error)
        }
    }

    private func downloadAndInstallTheme(from url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.showError(error)
                    return
                }
                guard let data else {
                    self?.showError(TerminalThemeError.unsupportedFormat)
                    return
                }
                do {
                    let imported = try TerminalThemeImporter.importTheme(
                        data: data,
                        filename: url.lastPathComponent,
                        sourceURL: url.absoluteString
                    )
                    let saved = try TerminalThemeStore.shared.saveImportedTheme(imported)
                    self?.selectAndApplyTheme(saved)
                } catch {
                    self?.showError(error)
                }
            }
        }.resume()
    }

    private func selectAndApplyTheme(_ theme: TerminalColorTheme) {
        populateThemes()
        TerminalThemeStore.shared.setActiveTheme(id: theme.id)
        prefs.cursorColorHex = theme.cursorHex
        loadCurrentValues()
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }

    private func selectedTheme() -> TerminalColorTheme? {
        themePopUp.selectedItem?.representedObject as? TerminalColorTheme
    }

    private func updateDeleteButton() {
        deleteThemeButton.isEnabled = selectedTheme()?.source != .builtIn
    }

    private func themeMenuTitle(_ theme: TerminalColorTheme) -> String {
        switch theme.source {
        case .builtIn:
            return theme.displayName
        case .imported:
            return "\(theme.displayName)  Imported"
        case .custom:
            return "\(theme.displayName)  Custom"
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
}

// MARK: - Theme Catalog

private final class ThemeCatalogWindowController: NSWindowController {
    init(onInstall: @escaping (TerminalColorTheme) -> Void) {
        let contentVC = ThemeCatalogViewController(onInstall: onInstall)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Theme Catalog"
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
    private let installButton = NSButton(title: "Install", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

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

        searchField.placeholderString = "Search \(catalog.displayName)"
        searchField.delegate = self

        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 28

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
        column.title = "Theme"
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

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
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
        setLoading(true, message: "Loading \(catalog.displayName)...")
        items = []
        applyFilter()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await client.fetchItems()
                await MainActor.run {
                    self.items = fetched
                    self.applyFilter()
                    self.setLoading(false, message: "\(fetched.count) themes available from \(self.catalog.displayName).")
                }
            } catch {
                await MainActor.run {
                    self.setLoading(false, message: "Could not load catalog.")
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
        setLoading(true, message: "Installing \(item.displayName)...")

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
                    self.setLoading(false, message: "Could not install \(item.displayName).")
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

// MARK: - Theme Editor

private final class ThemeEditorWindowController: NSWindowController {
    init(
        theme: TerminalColorTheme,
        replacingID: String?,
        onSave: @escaping (TerminalColorTheme) -> Void
    ) {
        let contentVC = ThemeEditorViewController(theme: theme, replacingID: replacingID, onSave: onSave)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Customize Theme"
        window.contentViewController = contentVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ThemeEditorViewController: NSViewController, NSTextFieldDelegate {
    private struct ColorControl {
        let well: NSColorWell
        let field: NSTextField
    }

    private let originalTheme: TerminalColorTheme
    private let replacingID: String?
    private let onSave: (TerminalColorTheme) -> Void

    private let nameField = NSTextField()
    private var backgroundControl: ColorControl!
    private var foregroundControl: ColorControl!
    private var cursorControl: ColorControl!
    private var ansiControls: [ColorControl] = []

    init(
        theme: TerminalColorTheme,
        replacingID: String?,
        onSave: @escaping (TerminalColorTheme) -> Void
    ) {
        self.originalTheme = theme
        self.replacingID = replacingID
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 620, height: 720))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    private func buildUI() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        view.addSubview(scrollView)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 10

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.alignment = .right
        nameLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true

        nameField.stringValue = originalTheme.source == .builtIn
            ? "\(originalTheme.displayName) Custom"
            : originalTheme.displayName
        nameField.widthAnchor.constraint(equalToConstant: 360).isActive = true

        nameRow.addArrangedSubview(nameLabel)
        nameRow.addArrangedSubview(nameField)
        stack.addArrangedSubview(nameRow)

        stack.addArrangedSubview(separator())
        backgroundControl = addColorRow("Background", originalTheme.backgroundHex, to: stack)
        foregroundControl = addColorRow("Foreground", originalTheme.foregroundHex, to: stack)
        cursorControl = addColorRow("Cursor", originalTheme.cursorHex, to: stack)
        stack.addArrangedSubview(separator())

        let ansiTitle = NSTextField(labelWithString: "ANSI Palette")
        ansiTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(ansiTitle)

        ansiControls = []
        for (idx, hex) in originalTheme.ansiHex.enumerated() {
            ansiControls.append(addColorRow("ANSI \(idx)", hex, to: stack))
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonRow)

        let saveButton = NSButton(title: "Save Theme", target: self, action: #selector(saveTheme))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            buttonRow.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func addColorRow(_ label: String, _ hex: String, to stack: NSStackView) -> ColorControl {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let well = NSColorWell()
        well.color = NSColor(soyehtHex: hex) ?? .black
        well.target = self
        well.action = #selector(colorWellChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let field = NSTextField()
        field.stringValue = TerminalColorTheme.normalizedHex(hex) ?? hex
        field.delegate = self
        field.target = self
        field.action = #selector(hexFieldChanged(_:))
        field.widthAnchor.constraint(equalToConstant: 95).isActive = true

        row.addArrangedSubview(text)
        row.addArrangedSubview(well)
        row.addArrangedSubview(field)
        stack.addArrangedSubview(row)
        return ColorControl(well: well, field: field)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return box
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        guard let control = allControls().first(where: { $0.well === sender }) else { return }
        control.field.stringValue = sender.color.soyehtHexString
    }

    @objc private func hexFieldChanged(_ sender: NSTextField) {
        applyHexField(sender)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        applyHexField(field)
    }

    private func applyHexField(_ field: NSTextField) {
        guard let control = allControls().first(where: { $0.field === field }),
              let normalized = TerminalColorTheme.normalizedHex(field.stringValue),
              let color = NSColor(soyehtHex: normalized) else {
            return
        }
        field.stringValue = normalized
        control.well.color = color
    }

    @objc private func saveTheme() {
        do {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let theme = TerminalColorTheme(
                id: replacingID ?? TerminalColorTheme.slug(name),
                displayName: name,
                backgroundHex: try hexValue(backgroundControl),
                foregroundHex: try hexValue(foregroundControl),
                cursorHex: try hexValue(cursorControl),
                ansiHex: try ansiControls.map(hexValue),
                source: .custom,
                sourceURL: originalTheme.sourceURL
            )
            let saved = try TerminalThemeStore.shared.saveCustomTheme(theme, replacing: replacingID)
            onSave(saved)
            closeEditor()
        } catch {
            showError(error)
        }
    }

    @objc private func cancel() {
        closeEditor()
    }

    private func hexValue(_ control: ColorControl) throws -> String {
        if let normalized = TerminalColorTheme.normalizedHex(control.field.stringValue) {
            return normalized
        }
        return try TerminalColorTheme.requireHex(control.well.color.soyehtHexString)
    }

    private func allControls() -> [ColorControl] {
        [backgroundControl, foregroundControl, cursorControl].compactMap { $0 } + ansiControls
    }

    private func closeEditor() {
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
}

private extension NSColor {
    var soyehtHexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

extension PreferencesViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === fontSizeField,
              let size = Double(field.stringValue) else { return }
        let clamped = max(TerminalPreferences.minimumFontSize, min(32, CGFloat(size)))
        fontSizeStepper.doubleValue = Double(clamped)
        applyFontSize(clamped)
    }
}
