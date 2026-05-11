import UIKit
import SoyehtCore

@MainActor
protocol VoiceRecordingPanelDelegate: AnyObject {
    func recordingPanelDidTapSend(_ panel: VoiceRecordingPanel)
    func recordingPanelDidTapCancel(_ panel: VoiceRecordingPanel)
}

final class VoiceRecordingPanel: UIView {
    weak var delegate: VoiceRecordingPanelDelegate?

    // Subviews
    private let controlBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let recordingDot = UIView()
    private let timerLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    let waveformView = VoiceWaveformView()
    private let transcriptionBox = UIView()
    private let transcriptionLabel = UILabel()
    private let transcriptionText = UITextView()
    private let bottomBar = UIView()
    private let bottomIcon = UIImageView()
    private let bottomLabel = UILabel()

    private var timerUpdater: Timer?
    private var recordingStart = Date()
    private var dotBlinkTimer: Timer?
    private let topBorder = UIView()

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
        backgroundColor = SoyehtTheme.uiBgPrimary
        clipsToBounds = true

        setupControlBar()
        setupBottomBar()
        setupWaveform()
        setupTranscription()
        applyTheme()
        startTimers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyTheme),
            name: .soyehtColorThemeChanged,
            object: nil
        )
    }

    private func setupControlBar() {
        controlBar.backgroundColor = SoyehtTheme.uiBgKeybarFrame
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlBar)

        topBorder.backgroundColor = SoyehtTheme.uiEnterGreen
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(topBorder)

        // Cancel button
        cancelButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: Typography.iconNavPointSize, weight: .bold)), for: .normal)
        cancelButton.tintColor = SoyehtTheme.uiKillRed
        cancelButton.backgroundColor = SoyehtTheme.uiBgKill
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        controlBar.addSubview(cancelButton)

        // Recording dot
        recordingDot.backgroundColor = SoyehtTheme.uiKillRed
        recordingDot.layer.cornerRadius = 4
        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(recordingDot)

        // Timer label
        timerLabel.text = "Recording 0:00"
        timerLabel.font = Typography.monoUILabelMedium
        timerLabel.textColor = SoyehtTheme.uiTextPrimary
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(timerLabel)

        // Send button — visible immediately
        let sendSymbolConfig = UIImage.SymbolConfiguration(pointSize: Typography.iconNavPointSize, weight: .medium)
        var sendConfig = UIButton.Configuration.plain()
        sendConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        sendConfig.title = String(localized: "voice.button.send", comment: "Primary button in the voice recording panel that sends the transcription. Includes a trailing space before the paperplane icon.")
        sendConfig.image = UIImage(systemName: "paperplane.fill", withConfiguration: sendSymbolConfig)
        sendConfig.imagePlacement = .trailing
        sendConfig.imagePadding = 0
        sendConfig.background.backgroundColor = SoyehtTheme.uiBgEnter
        sendConfig.background.strokeColor = SoyehtTheme.uiEnterGreen
        sendConfig.background.strokeWidth = 1
        sendConfig.baseForegroundColor = SoyehtTheme.uiEnterGreen
        sendButton.configuration = sendConfig
        sendButton.tintColor = SoyehtTheme.uiEnterGreen
        sendButton.titleLabel?.font = Typography.monoUILabelMedium
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        controlBar.addSubview(sendButton)

        NSLayoutConstraint.activate([
            controlBar.topAnchor.constraint(equalTo: topAnchor),
            controlBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 40),

            topBorder.topAnchor.constraint(equalTo: controlBar.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            cancelButton.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 12),
            cancelButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 30),
            cancelButton.heightAnchor.constraint(equalToConstant: 26),

            recordingDot.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            recordingDot.widthAnchor.constraint(equalToConstant: 8),
            recordingDot.heightAnchor.constraint(equalToConstant: 8),

            timerLabel.leadingAnchor.constraint(equalTo: recordingDot.trailingAnchor, constant: 6),
            timerLabel.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            timerLabel.centerXAnchor.constraint(equalTo: controlBar.centerXAnchor, constant: 10),

            recordingDot.trailingAnchor.constraint(equalTo: timerLabel.leadingAnchor, constant: -6),

            sendButton.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
        ])
    }

    private func setupWaveform() {
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waveformView)

        NSLayoutConstraint.activate([
            waveformView.topAnchor.constraint(equalTo: controlBar.bottomAnchor, constant: 12),
            waveformView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            waveformView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            waveformView.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    private func setupTranscription() {
        transcriptionBox.backgroundColor = SoyehtTheme.uiBgCard
        transcriptionBox.layer.borderWidth = 1
        transcriptionBox.layer.borderColor = SoyehtTheme.uiDivider.cgColor
        transcriptionBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(transcriptionBox)

        transcriptionLabel.text = "Transcription:"
        transcriptionLabel.font = Typography.monoUILabelRegular
        transcriptionLabel.textColor = SoyehtTheme.uiTextSecondary
        transcriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptionBox.addSubview(transcriptionLabel)

        transcriptionText.text = ""
        transcriptionText.font = Typography.monoUILabelRegular
        transcriptionText.textColor = SoyehtTheme.uiTextPrimary
        transcriptionText.backgroundColor = .clear
        transcriptionText.isEditable = false
        transcriptionText.isScrollEnabled = true
        transcriptionText.showsVerticalScrollIndicator = true
        transcriptionText.textContainerInset = .zero
        transcriptionText.textContainer.lineFragmentPadding = 0
        transcriptionText.translatesAutoresizingMaskIntoConstraints = false
        transcriptionBox.addSubview(transcriptionText)

        NSLayoutConstraint.activate([
            transcriptionBox.topAnchor.constraint(equalTo: waveformView.bottomAnchor, constant: 12),
            transcriptionBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            transcriptionBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            transcriptionBox.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),

            transcriptionLabel.topAnchor.constraint(equalTo: transcriptionBox.topAnchor, constant: 10),
            transcriptionLabel.leadingAnchor.constraint(equalTo: transcriptionBox.leadingAnchor, constant: 12),

            transcriptionText.topAnchor.constraint(equalTo: transcriptionLabel.bottomAnchor, constant: 4),
            transcriptionText.leadingAnchor.constraint(equalTo: transcriptionBox.leadingAnchor, constant: 12),
            transcriptionText.trailingAnchor.constraint(equalTo: transcriptionBox.trailingAnchor, constant: -12),
            transcriptionText.bottomAnchor.constraint(equalTo: transcriptionBox.bottomAnchor, constant: -10),
        ])
    }

    private func setupBottomBar() {
        bottomBar.backgroundColor = SoyehtTheme.uiBgEnter
        bottomBar.layer.borderWidth = 1
        bottomBar.layer.borderColor = SoyehtTheme.uiEnterGreen.cgColor
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBar)

        let config = UIImage.SymbolConfiguration(pointSize: Typography.iconStatusBoldPointSize, weight: .medium)
        bottomIcon.image = UIImage(systemName: "mic.fill", withConfiguration: config)
        bottomIcon.tintColor = SoyehtTheme.uiEnterGreen
        bottomIcon.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(bottomIcon)

        bottomLabel.text = "Listening..."
        bottomLabel.font = Typography.monoUILabelMedium
        bottomLabel.textColor = SoyehtTheme.uiEnterGreen
        bottomLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(bottomLabel)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),

            bottomIcon.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            bottomIcon.trailingAnchor.constraint(equalTo: bottomLabel.leadingAnchor, constant: -8),

            bottomLabel.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor, constant: 10),
            bottomLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])
    }

    // MARK: - Timers

    private func startTimers() {
        recordingStart = Date()

        timerUpdater = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateTimerDisplay()
        }

        dotBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            UIView.animate(withDuration: 0.3) {
                self?.recordingDot.alpha = self?.recordingDot.alpha == 1 ? 0.2 : 1
            }
        }

        waveformView.startAnimating()
    }

    private func updateTimerDisplay() {
        let elapsed = Int(Date().timeIntervalSince(recordingStart))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        timerLabel.text = String(format: "Recording %d:%02d", minutes, seconds)
    }

    // MARK: - Public State Updates

    func updateTranscription(_ text: String) {
        transcriptionText.text = text
        // Auto-scroll to bottom as text grows
        let bottom = NSRange(location: text.count, length: 0)
        transcriptionText.scrollRangeToVisible(bottom)
    }

    // MARK: - Cleanup

    func stopTimers() {
        timerUpdater?.invalidate()
        timerUpdater = nil
        dotBlinkTimer?.invalidate()
        dotBlinkTimer = nil
        waveformView.stopAnimating()
    }

    @objc private func applyTheme() {
        backgroundColor = SoyehtTheme.uiBgPrimary
        controlBar.backgroundColor = SoyehtTheme.uiBgKeybarFrame
        topBorder.backgroundColor = SoyehtTheme.uiEnterGreen
        cancelButton.tintColor = SoyehtTheme.uiKillRed
        cancelButton.backgroundColor = SoyehtTheme.uiBgKill
        recordingDot.backgroundColor = SoyehtTheme.uiKillRed
        timerLabel.textColor = SoyehtTheme.uiTextPrimary
        applySendButtonTheme()
        transcriptionBox.backgroundColor = SoyehtTheme.uiBgCard
        transcriptionBox.layer.borderColor = SoyehtTheme.uiDivider.cgColor
        transcriptionLabel.textColor = SoyehtTheme.uiTextSecondary
        transcriptionText.textColor = SoyehtTheme.uiTextPrimary
        bottomBar.backgroundColor = SoyehtTheme.uiBgEnter
        bottomBar.layer.borderColor = SoyehtTheme.uiEnterGreen.cgColor
        bottomIcon.tintColor = SoyehtTheme.uiEnterGreen
        bottomLabel.textColor = SoyehtTheme.uiEnterGreen
        waveformView.applyTheme()
    }

    private func applySendButtonTheme() {
        guard var config = sendButton.configuration else { return }
        config.background.backgroundColor = SoyehtTheme.uiBgEnter
        config.background.strokeColor = SoyehtTheme.uiEnterGreen
        config.baseForegroundColor = SoyehtTheme.uiEnterGreen
        sendButton.configuration = config
        sendButton.tintColor = SoyehtTheme.uiEnterGreen
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        HapticEngine.shared.play(for: "voiceCancel")
        delegate?.recordingPanelDidTapCancel(self)
    }

    @objc private func sendTapped() {
        HapticEngine.shared.play(for: "voiceSend")
        delegate?.recordingPanelDidTapSend(self)
    }
}
