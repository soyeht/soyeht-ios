import AppKit
import SoyehtCore
import UniformTypeIdentifiers

/// Getting a theme from outside the app: a file the user picks, the online
/// catalog, a URL they paste. Separate from `PreferencesWindowController`
/// because that file is a preferences FORM, and a structure test guards the
/// split — the catalog and editor windows were once inlined there and the
/// file sprawled.
extension PreferencesViewController {
    @objc func importThemeFromFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "prefs.theme.importPanel.title")
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

    @objc func browseThemeCatalog() {
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

    @objc func installThemeFromURL() {
        let alert = NSAlert()
        alert.messageText = String(localized: "prefs.theme.installURL.title")
        alert.informativeText = String(localized: "prefs.theme.installURL.message")
        alert.addButton(withTitle: String(localized: "prefs.theme.button.install"))
        alert.addButton(withTitle: String(localized: "common.button.cancel"))

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

    func installTheme(from url: URL) {
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

    func downloadAndInstallTheme(from url: URL) {
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
}
