import UIKit

// Drag handle at the bottom edge of the scrollback panel: a thin strip
// with a centered pill. The whole surface is also a `UIButton`, which is
// how VoiceOver / Switch Control users expand or collapse the panel —
// the gesture and the tap coexist, UIKit arbitrates so a brief tap
// never starts a drag.
final class ScrollbackDragHandleView: UIView {

    static let height: CGFloat = 14

    let tapButton = UIButton(type: .system)
    private let pill = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        pill.backgroundColor = UIColor.tertiaryLabel
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.isUserInteractionEnabled = false

        tapButton.translatesAutoresizingMaskIntoConstraints = false
        tapButton.backgroundColor = backgroundColor
        tapButton.setTitle("", for: .normal)

        addSubview(tapButton)
        addSubview(pill)

        NSLayoutConstraint.activate([
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.widthAnchor.constraint(equalToConstant: 28),
            pill.heightAnchor.constraint(equalToConstant: 3)
        ])
    }

    required init?(coder: NSCoder) { fatalError("ScrollbackDragHandleView does not support coder init") }

    func applyAppearance(backgroundColor: UIColor, revealProgress: CGFloat) {
        let progress = max(0, min(1, revealProgress))
        let fill = backgroundColor.withAlphaComponent(progress)
        self.backgroundColor = fill
        layer.backgroundColor = fill.cgColor
        tapButton.backgroundColor = fill
        pill.alpha = max(0.9, progress)
    }
}
