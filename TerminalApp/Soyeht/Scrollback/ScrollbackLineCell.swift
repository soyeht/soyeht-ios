import UIKit

// Single-line cell that renders an `NSAttributedString` produced by
// `AnsiAttributedStringBuilder`. Fixed row height, non-interactive.
// VoiceOver reads the plain text of the attributed content.
final class ScrollbackLineCell: UICollectionViewCell {
    static let reuseID = "ScrollbackLineCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("ScrollbackLineCell does not support coder init") }

    func configure(attributed: NSAttributedString) {
        label.attributedText = attributed
        // VoiceOver reads plain text; ANSI attributes wouldn't make sense as speech.
        accessibilityLabel = attributed.string
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.attributedText = nil
        accessibilityLabel = nil
    }
}
