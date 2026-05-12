import SoyehtCore
import UIKit

enum FileRowPhase: Equatable {
    case idle
    case downloading(progress: Double, speedText: String?)
    case failed(message: String)
}

struct FileRowDownloadState: Equatable {
    var phase: FileRowPhase
    var opensPreviewOnCompletion: Bool
    var startedAt: TimeInterval
}

final class FileBrowserCell: UICollectionViewListCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let errorBanner = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let actionButton = UIButton(type: .system)

    var onCancelTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCancelTapped = nil
        onRetryTapped = nil
    }

    private func setup() {
        contentView.backgroundColor = SoyehtTheme.uiBgPrimary
        isAccessibilityElement = true
        accessibilityTraits = [.button]

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false

        titleLabel.font = Typography.monoUISection
        titleLabel.textColor = SoyehtTheme.uiTextPrimary
        titleLabel.numberOfLines = 1
        titleLabel.isAccessibilityElement = false

        subtitleLabel.font = Typography.monoUILabelRegular
        subtitleLabel.textColor = SoyehtTheme.uiTextSecondary
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isAccessibilityElement = false

        progressLabel.font = Typography.monoUILabelSemi
        progressLabel.textColor = SoyehtTheme.uiAccentGreen
        progressLabel.isHidden = true
        progressLabel.isAccessibilityElement = false

        progressView.tintColor = SoyehtTheme.uiAccentGreen
        progressView.trackTintColor = SoyehtTheme.uiDivider
        progressView.isHidden = true
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.accessibilityIdentifier = AccessibilityID.FilePreview.progressView
        progressView.isAccessibilityElement = false

        errorBanner.font = Typography.monoUILabelSemi
        errorBanner.textColor = SoyehtTheme.uiTextPrimary
        errorBanner.backgroundColor = SoyehtTheme.uiBgKill
        errorBanner.textAlignment = .center
        errorBanner.numberOfLines = 0
        errorBanner.layer.cornerRadius = 0
        errorBanner.clipsToBounds = true
        errorBanner.isHidden = true
        errorBanner.isAccessibilityElement = false

        chevronView.tintColor = SoyehtTheme.uiTextSecondary
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.contentMode = .scaleAspectFit
        chevronView.isAccessibilityElement = false

        actionButton.titleLabel?.font = Typography.monoUILabelSemi
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isAccessibilityElement = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, progressLabel, progressView, errorBanner])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let rowStack = UIStackView(arrangedSubviews: [iconView, textStack, actionButton, chevronView])
        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 16),

            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    func configure(
        entry: RemoteDirectoryEntry,
        subtitle: String,
        icon: UIImage?,
        iconTint: UIColor,
        state: FileRowDownloadState?
    ) {
        iconView.image = icon
        iconView.tintColor = iconTint
        titleLabel.text = entry.name
        subtitleLabel.text = subtitle
        accessibilityLabel = entry.name
        accessibilityValue = subtitle
        progressLabel.accessibilityIdentifier = AccessibilityID.FileBrowser.rowProgress(entry.path)
        errorBanner.accessibilityIdentifier = AccessibilityID.FileBrowser.rowError(entry.path)
        actionButton.accessibilityIdentifier = AccessibilityID.FileBrowser.rowAction(entry.path)
        progressLabel.isAccessibilityElement = false
        errorBanner.isAccessibilityElement = false
        actionButton.isAccessibilityElement = false
        chevronView.isHidden = !entry.isDirectory
        actionButton.isHidden = true
        progressLabel.isHidden = true
        progressView.isHidden = true
        errorBanner.isHidden = true
        subtitleLabel.isHidden = false

        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = SoyehtTheme.uiBgPrimary
        background.strokeColor = SoyehtTheme.uiDivider
        background.strokeWidth = 1
        background.cornerRadius = 0
        background.backgroundInsets = .zero
        self.backgroundConfiguration = background

        switch state?.phase ?? .idle {
        case .idle:
            break
        case .downloading(let progress, let speedText):
            subtitleLabel.isHidden = true
            progressLabel.isHidden = false
            progressView.isHidden = false
            progressView.progress = Float(progress)
            let summary = progressSummary(progress: progress, speedText: speedText)
            progressLabel.text = summary
            accessibilityValue = summary
            progressLabel.accessibilityValue = summary
            progressLabel.isAccessibilityElement = true
            actionButton.isHidden = false
            chevronView.isHidden = true
            actionButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            actionButton.setTitle(nil, for: .normal)
            actionButton.tintColor = SoyehtTheme.uiTextSecondary
            actionButton.accessibilityLabel = String(localized: "fileBrowser.download.cancel.a11y")
            actionButton.isAccessibilityElement = true
            actionButton.removeTarget(nil, action: nil, for: .allEvents)
            actionButton.addAction(UIAction { [weak self] _ in self?.onCancelTapped?() }, for: .touchUpInside)
        case .failed(let message):
            subtitleLabel.isHidden = true
            errorBanner.isHidden = false
            errorBanner.text = "  \(message)  "
            accessibilityValue = message
            errorBanner.accessibilityValue = message
            errorBanner.isAccessibilityElement = true
            actionButton.isHidden = false
            chevronView.isHidden = true
            actionButton.setImage(nil, for: .normal)
            actionButton.setTitle(String(localized: "common.button.retry"), for: .normal)
            actionButton.setTitleColor(SoyehtTheme.uiAccentGreen, for: .normal)
            actionButton.accessibilityLabel = String(localized: "fileBrowser.download.retry.a11y")
            actionButton.isAccessibilityElement = true
            actionButton.removeTarget(nil, action: nil, for: .allEvents)
            actionButton.addAction(UIAction { [weak self] _ in self?.onRetryTapped?() }, for: .touchUpInside)
        }
    }

    private func progressSummary(progress: Double, speedText: String?) -> String {
        let percent = Int((progress * 100).rounded())
        if let speedText, !speedText.isEmpty {
            return "\(percent)% · \(speedText)"
        }
        return "\(percent)%"
    }
}
