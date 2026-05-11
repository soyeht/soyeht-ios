import UIKit
import SoyehtCore

@MainActor
protocol VoiceBarViewDelegate: AnyObject {
    func voiceBarDidTap(_ bar: VoiceBarView)
}

final class VoiceBarView: UIView {
    static let preferredHeight: CGFloat = 44

    weak var delegate: VoiceBarViewDelegate?

    private let contentStack = UIStackView()
    private let micIcon = UIImageView()
    private let tapLabel = UILabel()
    private let topBorder = UIView()
    private let langButton = UIButton(type: .system)

    private let languages: [(id: String, short: String, name: String)] = [
        ("auto", "AUTO", "Auto (Device)"),
        ("en-US", "EN", "English (US)"),
        ("en-GB", "EN-GB", "English (UK)"),
        ("pt-BR", "PT-BR", "Portuguese (BR)"),
        ("pt-PT", "PT", "Portuguese (PT)"),
        ("es-ES", "ES", "Spanish (ES)"),
        ("es-MX", "ES-MX", "Spanish (MX)"),
        ("fr-FR", "FR", "French"),
        ("de-DE", "DE", "German"),
        ("ja-JP", "JA", "Japanese"),
        ("zh-CN", "ZH", "Chinese (Simplified)"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = SoyehtTheme.uiBgKeybarFrame

        // Top border
        topBorder.backgroundColor = SoyehtTheme.uiTopBorder
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        // Mic icon
        let config = UIImage.SymbolConfiguration(pointSize: Typography.iconMediumPointSize, weight: .medium)
        micIcon.image = UIImage(systemName: "mic.fill", withConfiguration: config)
        micIcon.tintColor = SoyehtTheme.uiEnterGreen
        micIcon.contentMode = .scaleAspectFit

        // Label
        tapLabel.text = "Tap to speak"
        tapLabel.font = Typography.monoUICardMedium
        tapLabel.textColor = SoyehtTheme.uiEnterGreen

        // Centered horizontal stack
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 10
        contentStack.addArrangedSubview(micIcon)
        contentStack.addArrangedSubview(tapLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        // Language button with menu
        var langConfig = UIButton.Configuration.plain()
        langConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        langConfig.background.backgroundColor = SoyehtTheme.uiTopBorder
        langConfig.background.cornerRadius = 4
        langConfig.baseForegroundColor = SoyehtTheme.uiTextSecondary
        langButton.configuration = langConfig
        langButton.titleLabel?.font = Typography.monoUILabelMedium
        langButton.translatesAutoresizingMaskIntoConstraints = false
        langButton.showsMenuAsPrimaryAction = true
        addSubview(langButton)

        updateLangButton()
        buildLangMenu()

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            micIcon.widthAnchor.constraint(equalToConstant: 20),
            micIcon.heightAnchor.constraint(equalToConstant: 20),

            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            langButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            langButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Tap gesture on the main area (not the lang button)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: .soyehtColorThemeChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeChanged() {
        applyTheme()
    }

    func applyTheme() {
        backgroundColor = SoyehtTheme.uiBgKeybarFrame
        topBorder.backgroundColor = SoyehtTheme.uiTopBorder
        micIcon.tintColor = SoyehtTheme.uiEnterGreen
        tapLabel.textColor = SoyehtTheme.uiEnterGreen

        var langConfig = langButton.configuration ?? UIButton.Configuration.plain()
        langConfig.background.backgroundColor = SoyehtTheme.uiTopBorder
        langConfig.baseForegroundColor = SoyehtTheme.uiTextSecondary
        langButton.configuration = langConfig
    }

    private func updateLangButton() {
        let current = TerminalPreferences.shared.voiceLanguage
        let short = languages.first(where: { $0.id == current })?.short ?? "AUTO"
        langButton.setTitle(short, for: .normal)
    }

    private func buildLangMenu() {
        let current = TerminalPreferences.shared.voiceLanguage
        let actions = languages.map { lang in
            UIAction(
                title: lang.name,
                state: lang.id == current ? .on : .off
            ) { [weak self] _ in
                TerminalPreferences.shared.voiceLanguage = lang.id
                self?.updateLangButton()
                self?.buildLangMenu()
                NotificationCenter.default.post(name: .soyehtVoiceInputSettingsChanged, object: nil)
            }
        }
        langButton.menu = UIMenu(children: actions)
    }

    // MARK: - Gesture

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Don't trigger recording if the tap was on the language button
        let location = gesture.location(in: self)
        guard !langButton.frame.contains(location) else { return }
        delegate?.voiceBarDidTap(self)
    }

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }
}
