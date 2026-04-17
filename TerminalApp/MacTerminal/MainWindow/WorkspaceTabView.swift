import AppKit
import SoyehtCore

/// Single workspace tab rendered inside `WorkspaceTitlebarAccessoryController`.
/// Mirrors the Pencil design (`mj4II`/`7tzfH`/`9WPaI`):
/// - Active  : fill #161616, bottom 2pt stroke #10B981, green 6pt dot, label
///             `#FAFAFA 12pt`, optional count `#6B7280 11pt`.
/// - Idle    : no fill, label `#8A8A8A 12pt`, optional count `#3A3A3A 11pt`.
@MainActor
final class WorkspaceTabView: NSView {

    private static let greenAccent = NSColor(calibratedRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let activeFill  = NSColor(calibratedRed: 0x16/255, green: 0x16/255, blue: 0x16/255, alpha: 1)
    private static let activeLabel = NSColor(calibratedRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1)
    private static let idleLabel   = NSColor(calibratedRed: 0x8A/255, green: 0x8A/255, blue: 0x8A/255, alpha: 1)
    private static let countActive = NSColor(calibratedRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let countIdle   = NSColor(calibratedRed: 0x3A/255, green: 0x3A/255, blue: 0x3A/255, alpha: 1)

    let workspaceID: Workspace.ID
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let bottomStroke = NSView()
    private var isActive: Bool = false
    private let title: String
    private let count: Int

    var onClick: (() -> Void)?

    /// Right-click handler. Returns an `NSMenu` to pop up at the click
    /// location, or `nil` to fall through to the default behaviour. The
    /// accessory controller owns menu construction; the tab view is dumb.
    var onRequestContextMenu: ((Workspace.ID) -> NSMenu?)?

    init(workspaceID: Workspace.ID, title: String, count: Int = 0, isActive: Bool) {
        self.workspaceID = workspaceID
        self.isActive = isActive
        self.title = title
        self.count = count
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace tab \(title)")
        setAccessibilityValue(isActive ? "selected" : "not selected")
        focusRingType = .default

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = Self.greenAccent.cgColor
        addSubview(dot)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.monoNSFont(size: 12, weight: .regular)
        label.stringValue = title
        addSubview(label)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Typography.monoNSFont(size: 11, weight: .regular)
        countLabel.stringValue = count > 0 ? "\(count)" : ""
        addSubview(countLabel)

        bottomStroke.translatesAutoresizingMaskIntoConstraints = false
        bottomStroke.wantsLayer = true
        bottomStroke.layer?.backgroundColor = Self.greenAccent.cgColor
        addSubview(bottomStroke)

        // Design padding: [10, 14] → horizontal 14, vertical 10.
        NSLayoutConstraint.activate([
            // 6pt green dot (only visible when active)
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            bottomStroke.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomStroke.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomStroke.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomStroke.heightAnchor.constraint(equalToConstant: 2),

            heightAnchor.constraint(equalToConstant: 42),
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

    func setTitle(_ newTitle: String) {
        label.stringValue = newTitle
    }

    func setCount(_ newCount: Int) {
        countLabel.stringValue = newCount > 0 ? "\(newCount)" : ""
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func drawFocusRingMask() { bounds.fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
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
            layer?.backgroundColor = Self.activeFill.cgColor
            label.textColor = Self.activeLabel
            countLabel.textColor = Self.countActive
            dot.isHidden = false
            bottomStroke.isHidden = false
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = Self.idleLabel
            countLabel.textColor = Self.countIdle
            dot.isHidden = true
            bottomStroke.isHidden = true
        }
    }

    @objc private func handleClick() { onClick?() }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onRequestContextMenu?(workspaceID) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}
