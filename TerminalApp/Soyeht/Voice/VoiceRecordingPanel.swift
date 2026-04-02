import UIKit

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
        backgroundColor = UIColor(red: 0.02, green: 0.06, blue: 0.04, alpha: 1) // #050F0A
        clipsToBounds = true

        setupControlBar()
        setupBottomBar()
        setupWaveform()
        setupTranscription()
        startTimers()
    }

    private func setupControlBar() {
        controlBar.backgroundColor = SoyehtTheme.uiBgKeybarFrame
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlBar)

        // Top green border
        let border = UIView()
        border.backgroundColor = SoyehtTheme.uiEnterGreen.withAlphaComponent(0.25)
        border.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(border)

        // Cancel button
        cancelButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)), for: .normal)
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
        timerLabel.font = UIFont(name: "IBM Plex Mono", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        timerLabel.textColor = SoyehtTheme.uiTextPrimary
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(timerLabel)

        // Send button — visible immediately
        let sendConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        sendButton.setTitle("Send ", for: .normal)
        sendButton.setImage(UIImage(systemName: "paperplane.fill", withConfiguration: sendConfig), for: .normal)
        sendButton.tintColor = SoyehtTheme.uiEnterGreen
        sendButton.titleLabel?.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        sendButton.setTitleColor(SoyehtTheme.uiEnterGreen, for: .normal)
        sendButton.backgroundColor = SoyehtTheme.uiBgEnter
        sendButton.layer.borderWidth = 1
        sendButton.layer.borderColor = SoyehtTheme.uiEnterGreen.cgColor
        sendButton.semanticContentAttribute = .forceRightToLeft
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        controlBar.addSubview(sendButton)

        NSLayoutConstraint.activate([
            controlBar.topAnchor.constraint(equalTo: topAnchor),
            controlBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 40),

            border.topAnchor.constraint(equalTo: controlBar.topAnchor),
            border.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

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
        transcriptionBox.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1) // #0A0A0A
        transcriptionBox.layer.borderWidth = 1
        transcriptionBox.layer.borderColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1).cgColor // #1A1A1A
        transcriptionBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(transcriptionBox)

        transcriptionLabel.text = "Transcription:"
        transcriptionLabel.font = UIFont(name: "IBM Plex Mono", size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular)
        transcriptionLabel.textColor = SoyehtTheme.uiTextSecondary
        transcriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptionBox.addSubview(transcriptionLabel)

        transcriptionText.text = ""
        transcriptionText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        bottomBar.backgroundColor = SoyehtTheme.uiEnterGreen.withAlphaComponent(0.1)
        bottomBar.layer.borderWidth = 1
        bottomBar.layer.borderColor = SoyehtTheme.uiEnterGreen.withAlphaComponent(0.25).cgColor
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBar)

        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        bottomIcon.image = UIImage(systemName: "mic.fill", withConfiguration: config)
        bottomIcon.tintColor = SoyehtTheme.uiEnterGreen
        bottomIcon.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(bottomIcon)

        bottomLabel.text = "Listening..."
        bottomLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
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
