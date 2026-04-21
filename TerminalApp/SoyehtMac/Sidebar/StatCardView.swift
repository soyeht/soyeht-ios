import AppKit
import SoyehtCore

/// 4-up stat card used in the Conversations Sidebar detail pane.
/// Shows COMMANDER / SEQ / TOKENS / OPEN. Simple labeled value; no interaction.
@MainActor
final class StatCardView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")

    private let titleText: String

    init(title: String) {
        self.titleText = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(
            localized: "sidebar.statCard.a11y.empty",
            defaultValue: "\(title): —",
            comment: "VoiceOver label for a stat card with no value. %@ = title of the card."
        ))
        setAccessibilityChildren([])

        titleLabel.setAccessibilityElement(false)
        valueLabel.setAccessibilityElement(false)

        titleLabel.stringValue = title.uppercased()
        titleLabel.font = Typography.monoNSFont(size: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = Typography.monoNSFont(size: 20, weight: .semibold)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setValue(_ value: String) {
        valueLabel.stringValue = value
        setAccessibilityLabel(String(
            localized: "sidebar.statCard.a11y.value",
            defaultValue: "\(titleText): \(value)",
            comment: "VoiceOver label for a stat card with a value. %1$@ = title, %2$@ = value."
        ))
    }
}
