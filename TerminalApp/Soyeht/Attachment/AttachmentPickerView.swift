import UIKit

enum AttachmentOption {
    case photos
    case camera
    case location
    case document
    case files
}

final class AttachmentPickerView: UIInputView {
    var onOptionSelected: ((AttachmentOption) -> Void)?

    init() {
        let width = UIScreen.main.bounds.width
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 250), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        allowsSelfSizing = true
        backgroundColor = SoyehtTheme.uiBgAttachmentPanel
        setupGrid()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 250)
    }

    // MARK: - Layout

    private func setupGrid() {
        let row1 = makeRow([
            makeCard(icon: "photo", label: "Photos", color: SoyehtTheme.uiAttachPhoto, option: .photos),
            makeCard(icon: "camera", label: "Camera", color: SoyehtTheme.uiAttachCamera, option: .camera),
            makeCard(icon: "mappin", label: "Location", color: SoyehtTheme.uiAttachLocation, option: .location),
        ])
        let row2 = makeRow([
            makeCard(icon: "doc.text", label: "Documents", color: SoyehtTheme.uiAttachDocument, option: .document),
            makeCard(icon: "icloud", label: "Files", color: SoyehtTheme.uiAttachFiles, option: .files),
        ])

        let stack = UIStackView(arrangedSubviews: [row1, row2])
        stack.axis = .vertical
        stack.spacing = 16
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -44),
        ])
    }

    private func makeRow(_ cards: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: cards)
        row.axis = .horizontal
        row.spacing = 16
        row.distribution = .fillEqually
        return row
    }

    // MARK: - Card Factory

    private static var optionKey: UInt8 = 0

    private func makeCard(icon: String, label: String, color: UIColor, option: AttachmentOption) -> UIView {
        let card = UIButton(type: .system)
        card.backgroundColor = SoyehtTheme.uiBgAttachmentCard
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        // Icon
        let iconView = UIImageView()
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = color
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Label
        let labelView = UILabel()
        labelView.text = label
        labelView.font = .systemFont(ofSize: 12, weight: .medium)
        labelView.textColor = SoyehtTheme.uiTextPrimary
        labelView.textAlignment = .center
        labelView.translatesAutoresizingMaskIntoConstraints = false

        // Inner stack
        let inner = UIStackView(arrangedSubviews: [iconView, labelView])
        inner.axis = .vertical
        inner.alignment = .center
        inner.spacing = 8
        inner.isUserInteractionEnabled = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            inner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        objc_setAssociatedObject(card, &Self.optionKey, option, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        card.addTarget(self, action: #selector(cardTapped(_:)), for: .touchUpInside)
        return card
    }

    @objc private func cardTapped(_ sender: UIButton) {
        guard let option = objc_getAssociatedObject(sender, &Self.optionKey) as? AttachmentOption else { return }
        HapticEngine.shared.play(zone: .alphanumeric)
        onOptionSelected?(option)
    }
}
