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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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

    private let displayNameLabel = NSTextField(labelWithString: String(localized: "prefs.label.displayName", comment: "Preferences row label for the Mac's display name shown on paired iPhones."))
    private let displayNameField = NSTextField()

    private let automaticallyCheckForUpdatesButton = NSButton(
        checkboxWithTitle: String(localized: "prefs.checkbox.automaticallyCheckForUpdates", comment: "Preferences checkbox that enables automatic update checks."),
        target: nil,
        action: nil
    )

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 420, height: 260))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        populateThemes()
        loadCurrentValues()
    }

    private func buildUI() {
        [fontSizeLabel, fontSizeField, fontSizeStepper, themeLabel, themePopUp, displayNameLabel, displayNameField, automaticallyCheckForUpdatesButton].forEach {
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

            displayNameLabel.topAnchor.constraint(equalTo: themeLabel.bottomAnchor, constant: 20),
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
        for theme in ColorTheme.allCases {
            themePopUp.addItem(withTitle: String(localized: theme.displayName))
            themePopUp.lastItem?.representedObject = theme
        }
    }

    private func loadCurrentValues() {
        fontSizeStepper.doubleValue = Double(prefs.fontSize)
        fontSizeField.stringValue = String(Int(prefs.fontSize))

        let currentTheme = ColorTheme.active
        for (idx, item) in themePopUp.itemArray.enumerated() {
            if let theme = item.representedObject as? ColorTheme, theme == currentTheme {
                themePopUp.selectItem(at: idx)
                break
            }
        }

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
        guard let theme = themePopUp.selectedItem?.representedObject as? ColorTheme else { return }
        prefs.colorTheme = theme.rawValue
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }

    @objc private func automaticallyCheckForUpdatesChanged() {
        SoyehtUpdater.shared.automaticallyChecksForUpdates = automaticallyCheckForUpdatesButton.state == .on
    }

    private func applyFontSize(_ size: CGFloat) {
        prefs.fontSize = size
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
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
