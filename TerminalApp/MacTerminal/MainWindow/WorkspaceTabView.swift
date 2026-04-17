import AppKit
import SoyehtCore

/// Single workspace tab rendered inside `WorkspaceTitlebarAccessoryController`.
/// Active state uses Soyeht green (#10B981); idle tabs are a muted gray.
@MainActor
final class WorkspaceTabView: NSView {

    let workspaceID: Workspace.ID
    private let label = NSTextField(labelWithString: "")
    private let indicator = NSView()
    private var isActive: Bool = false
    private let title: String

    var onClick: (() -> Void)?

    init(workspaceID: Workspace.ID, title: String, isActive: Bool) {
        self.workspaceID = workspaceID
        self.isActive = isActive
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace tab \(title)")
        setAccessibilityValue(isActive ? "selected" : "not selected")
        focusRingType = .default

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.monoNSFont(size: 12, weight: .medium)
        label.stringValue = title
        addSubview(label)

        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 2
        addSubview(indicator)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            indicator.heightAnchor.constraint(equalToConstant: 2),
        ])

        applyStyle()

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        applyStyle()
        setAccessibilityValue(active ? "selected" : "not selected")
    }

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        // Return or Space activates the tab — matches NSButton behaviour.
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            onClick?()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private func applyStyle() {
        if isActive {
            label.textColor = NSColor(red: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1.0)
            indicator.layer?.backgroundColor = NSColor(red: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1.0).cgColor
        } else {
            label.textColor = NSColor.secondaryLabelColor
            indicator.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func handleClick() { onClick?() }
}
