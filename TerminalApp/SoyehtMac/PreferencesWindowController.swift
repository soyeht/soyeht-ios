//
//  PreferencesWindowController.swift
//  Soyeht
//
//  Cmd+, preferences: font size stepper + color theme picker.
//  Changes apply immediately to all open terminal tabs via NotificationCenter.
//

import Cocoa
import SoyehtCore
import UniformTypeIdentifiers

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
        panel.allowedContentTypes = ["itermcolors", "conf", "theme", "txt"].compactMap {
            UTType(filenameExtension: $0)
        }

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
