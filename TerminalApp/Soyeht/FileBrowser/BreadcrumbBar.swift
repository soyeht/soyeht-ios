import SoyehtCore
import UIKit

final class BreadcrumbBar: UIView {
    var onSegmentTapped: ((String) -> Void)?
    var onSegmentLongPressed: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var segmentPaths: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = SoyehtTheme.uiBgKeybar
        layer.borderColor = SoyehtTheme.uiDivider.cgColor
        layer.borderWidth = 1
        accessibilityIdentifier = AccessibilityID.FileBrowser.breadcrumbBar

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(path: String) {
        segmentPaths = buildSegmentPaths(for: path)
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, segmentPath) in segmentPaths.enumerated() {
            let title = segmentTitle(for: segmentPath)
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            button.configuration = configuration
            button.setTitle(title, for: .normal)
            button.setTitleColor(SoyehtTheme.uiTextPrimary, for: .normal)
            button.titleLabel?.font = Typography.monoUICardMedium
            button.tag = index
            button.addTarget(self, action: #selector(segmentTapped(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = AccessibilityID.FileBrowser.breadcrumbSegment(index)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(segmentLongPressed(_:)))
            button.addGestureRecognizer(longPress)
            stackView.addArrangedSubview(button)

            if index < segmentPaths.count - 1 {
                let separator = UILabel()
                separator.text = "/"
                separator.font = Typography.monoUILabelRegular
                separator.textColor = SoyehtTheme.uiTextSecondary
                stackView.addArrangedSubview(separator)
            }
        }
    }

    @objc private func segmentTapped(_ sender: UIButton) {
        guard sender.tag < segmentPaths.count else { return }
        onSegmentTapped?(segmentPaths[sender.tag])
    }

    @objc private func segmentLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onSegmentLongPressed?()
    }

    private func buildSegmentPaths(for path: String) -> [String] {
        if path == "/" { return ["/"] }

        let parts = path.split(separator: "/").map(String.init)
        if path.hasPrefix("/") {
            var result = ["/"]
            var accumulator = ""
            for part in parts {
                accumulator += "/\(part)"
                result.append(accumulator)
            }
            return result
        }

        var result: [String] = []
        var accumulator = ""
        for part in parts {
            accumulator = accumulator.isEmpty ? part : "\(accumulator)/\(part)"
            result.append(accumulator)
        }
        return result
    }

    private func segmentTitle(for path: String) -> String {
        if path == "/" { return path }
        return (path as NSString).lastPathComponent
    }
}
