import SoyehtCore
import UIKit

final class SourceChipStrip: UIView {
    var onOptionSelected: ((AttachmentOption) -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let options: [(key: String, option: AttachmentOption, color: UIColor, icon: String)] = [
        ("attachment.option.photos", .photos, SoyehtTheme.uiAttachPhoto, "photo"),
        ("attachment.option.camera", .camera, SoyehtTheme.uiAttachCamera, "camera"),
        ("attachment.option.documents", .document, SoyehtTheme.uiAttachDocument, "doc.text"),
        ("attachment.option.files", .files, SoyehtTheme.uiAttachFiles, "folder"),
        ("attachment.option.location", .location, SoyehtTheme.uiAttachLocation, "mappin"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = AccessibilityID.FileBrowser.sourceChipStrip
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        options.enumerated().forEach { index, item in
            let title = String(localized: String.LocalizationValue(item.key))
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = UIImage(systemName: item.icon)
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            configuration.cornerStyle = .fixed

            let button = UIButton(type: .system)
            button.configuration = configuration
            button.tintColor = item.color
            button.setTitleColor(SoyehtTheme.uiTextPrimary, for: .normal)
            button.titleLabel?.font = Typography.monoUILabelSemi
            button.backgroundColor = SoyehtTheme.uiBgKeybar
            button.layer.cornerRadius = 0
            button.layer.borderColor = item.color.cgColor
            button.layer.borderWidth = 1
            button.tag = index
            button.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = AccessibilityID.FileBrowser.sourceChip(title)
            stackView.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func chipTapped(_ sender: UIButton) {
        onOptionSelected?(options[sender.tag].option)
    }
}
