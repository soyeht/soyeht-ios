//
//  PreferencesWindowController.swift
//  MacTerminal
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.contentViewController = contentVC
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use PreferencesWindowController.shared") }
}

// MARK: -

class PreferencesViewController: NSViewController {

    private let prefs = TerminalPreferences.shared

    private let fontSizeLabel = NSTextField(labelWithString: "Font Size:")
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()

    private let themeLabel = NSTextField(labelWithString: "Color Theme:")
    private let themePopUp = NSPopUpButton()

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 360, height: 160))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        populateThemes()
        loadCurrentValues()
    }

    private func buildUI() {
        [fontSizeLabel, fontSizeField, fontSizeStepper, themeLabel, themePopUp].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        fontSizeLabel.alignment = .right
        fontSizeField.isEditable = true
        fontSizeField.isBezeled = true
        fontSizeField.bezelStyle = .squareBezel
        fontSizeField.delegate = self

        fontSizeStepper.minValue = 8
        fontSizeStepper.maxValue = 32
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(stepperChanged)

        themeLabel.alignment = .right

        themePopUp.target = self
        themePopUp.action = #selector(themeChanged)

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
        ])
    }

    private func populateThemes() {
        themePopUp.removeAllItems()
        for theme in ColorTheme.allCases {
            themePopUp.addItem(withTitle: theme.displayName)
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
        let clamped = max(8, min(32, CGFloat(size)))
        fontSizeStepper.doubleValue = Double(clamped)
        applyFontSize(clamped)
    }
}
