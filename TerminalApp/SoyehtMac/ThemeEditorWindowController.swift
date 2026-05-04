import Cocoa
import SoyehtCore

final class ThemeEditorWindowController: NSWindowController {
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
    private var cursorTextControl: ColorControl?
    private var selectionBackgroundControl: ColorControl?
    private var selectionForegroundControl: ColorControl?
    private var boldControl: ColorControl?
    private var linkControl: ColorControl?
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
        addOptionalSemanticColorRows(to: stack)
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
        well.color = NSColor(soyehtHex: hex) ?? MacTheme.surfaceDeep
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
                cursorTextHex: try optionalHexValue(cursorTextControl),
                selectionBackgroundHex: try optionalHexValue(selectionBackgroundControl),
                selectionForegroundHex: try optionalHexValue(selectionForegroundControl),
                boldHex: try optionalHexValue(boldControl),
                linkHex: try optionalHexValue(linkControl),
                ansiHex: try ansiControls.map(hexValue),
                source: .custom,
                sourceURL: originalTheme.sourceURL,
                extraHexColors: originalTheme.extraHexColors
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

    private func optionalHexValue(_ control: ColorControl?) throws -> String? {
        guard let control else { return nil }
        return try hexValue(control)
    }

    private func allControls() -> [ColorControl] {
        [
            backgroundControl,
            foregroundControl,
            cursorControl,
            cursorTextControl,
            selectionBackgroundControl,
            selectionForegroundControl,
            boldControl,
            linkControl,
        ].compactMap { $0 } + ansiControls
    }

    private func addOptionalSemanticColorRows(to stack: NSStackView) {
        let optionalColors = [
            originalTheme.cursorTextHex,
            originalTheme.selectionBackgroundHex,
            originalTheme.selectionForegroundHex,
            originalTheme.boldHex,
            originalTheme.linkHex,
        ]
        guard optionalColors.contains(where: { $0 != nil }) else { return }

        stack.addArrangedSubview(separator())

        let semanticTitle = NSTextField(labelWithString: "Terminal Semantic Colors")
        semanticTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(semanticTitle)

        cursorTextControl = addOptionalColorRow("Cursor Text", originalTheme.cursorTextHex, to: stack)
        selectionBackgroundControl = addOptionalColorRow("Selection Bg", originalTheme.selectionBackgroundHex, to: stack)
        selectionForegroundControl = addOptionalColorRow("Selection Text", originalTheme.selectionForegroundHex, to: stack)
        boldControl = addOptionalColorRow("Bold", originalTheme.boldHex, to: stack)
        linkControl = addOptionalColorRow("Link", originalTheme.linkHex, to: stack)
    }

    private func addOptionalColorRow(_ label: String, _ hex: String?, to stack: NSStackView) -> ColorControl? {
        guard let hex else { return nil }
        return addColorRow(label, hex, to: stack)
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
