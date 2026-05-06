import AppKit

@MainActor
protocol PaneVoiceInputControlling: AnyObject {
    func setVisible(_ visible: Bool)
    func applyTheme()
    func cancel()
}

@available(macOS 26.0, *)
@MainActor
final class MacVoicePaneInputController: NSObject, PaneVoiceInputControlling, MacVoiceInputServiceDelegate {
    private enum State {
        case idle
        case starting
        case recording
        case stopping
    }

    private enum Layout {
        static let buttonTrailingInset: CGFloat = 12
        static let buttonBottomInset: CGFloat = 14
        static let buttonSize: CGFloat = 36
    }

    private weak var hostView: NSView?
    private let service = MacVoiceInputService()
    private let onTextReady: (String) -> Void

    private let button = VoiceButton()
    private let previewLabel = VoicePreviewLabel(frame: .zero)
    private var task: Task<Void, Never>?
    private var hidePreviewWorkItem: DispatchWorkItem?
    private var emittedTranscription = ""
    private var recordingGeneration = 0
    private var state: State = .idle {
        didSet { updateAppearance() }
    }

    init(hostView: NSView, onTextReady: @escaping (String) -> Void) {
        self.hostView = hostView
        self.onTextReady = onTextReady
        super.init()
        service.delegate = self
        install(in: hostView)
        updateAppearance()
    }

    deinit {
        MacVoiceInputLog.write("controller.deinit")
        task?.cancel()
        Task { [service] in await service.cancelListening() }
    }

    func setVisible(_ visible: Bool) {
        button.isHidden = !visible
        if !visible {
            previewLabel.isHidden = true
            cancel()
        }
    }

    func applyTheme() {
        updateAppearance()
    }

    func cancel() {
        guard state != .idle else { return }
        recordingGeneration += 1
        let generation = recordingGeneration
        task?.cancel()
        task = Task { [weak self, generation] in
            guard let self else { return }
            await self.service.cancelListening()
            guard self.recordingGeneration == generation else { return }
            self.previewLabel.isHidden = true
            self.state = .idle
        }
    }

    func macVoiceInputDidUpdateTranscription(_ text: String) {
        MacVoiceInputLog.write("controller.transcriptionUpdate length=\(text.count), text='\(Self.preview(text))'")
        emitTranscriptionDelta(text)
    }

    func macVoiceInputDidUpdateStatus(_ message: String) {
        MacVoiceInputLog.write("controller.status: \(message)")
    }

    func macVoiceInputDidUpdateAudioLevel(_ level: Float) {
        let clamped = max(0, min(1, CGFloat(level)))
        button.layer?.shadowOpacity = Float(0.18 + clamped * 0.34)
    }

    func macVoiceInputDidFail(_ message: String) {
        MacVoiceInputLog.write("controller.failure: \(message)")
        showPreview(message, autoHide: true)
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.service.cancelListening()
            self.state = .idle
        }
    }

    @objc private func toggleRecording() {
        MacVoiceInputLog.write("controller.toggle state=\(state)")
        switch state {
        case .idle:
            startRecording()
        case .starting:
            cancel()
        case .recording:
            stopAndInsert()
        case .stopping:
            break
        }
    }

    private func install(in hostView: NSView) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOffset = CGSize(width: 0, height: -1)
        button.layer?.shadowRadius = 8
        button.layer?.shadowOpacity = 0.18
        button.target = self
        button.action = #selector(toggleRecording)
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(String(localized: "voice.mac.button.a11y", defaultValue: "Voice input"))

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.isHidden = true
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = MacTypography.NSFonts.Text.monoBody
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hostView.addSubview(previewLabel)
        hostView.addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: hostView.trailingAnchor, constant: -Layout.buttonTrailingInset),
            button.bottomAnchor.constraint(equalTo: hostView.bottomAnchor, constant: -Layout.buttonBottomInset),
            button.widthAnchor.constraint(equalToConstant: Layout.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Layout.buttonSize),

            previewLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            previewLabel.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -8),
            previewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            previewLabel.leadingAnchor.constraint(greaterThanOrEqualTo: hostView.leadingAnchor, constant: 12),
        ])
    }

    private func startRecording() {
        MacVoiceInputLog.reset()
        MacVoiceInputLog.write("controller.startRecording")
        recordingGeneration += 1
        let generation = recordingGeneration
        state = .starting
        emittedTranscription = ""
        previewLabel.isHidden = true

        task?.cancel()
        task = Task { [weak self, generation] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.service.startListening()
                try Task.checkCancellation()
                guard self.recordingGeneration == generation, self.state == .starting else {
                    MacVoiceInputLog.write("controller.startRecording ignored stale generation \(generation)")
                    return
                }
                MacVoiceInputLog.write("controller.service.startListening returned")
                self.state = .recording
                self.previewLabel.isHidden = true
            } catch is CancellationError {
                MacVoiceInputLog.write("controller.startRecording cancelled")
                guard self.recordingGeneration == generation else { return }
                await self.service.cancelListening()
                self.previewLabel.isHidden = true
                self.state = .idle
            } catch {
                guard self.recordingGeneration == generation else { return }
                MacVoiceInputLog.write("controller.startRecording failed: \(error.localizedDescription)")
                self.showPreview(error.localizedDescription, autoHide: true)
                self.state = .idle
            }
        }
    }

    private func stopAndInsert() {
        MacVoiceInputLog.write("controller.stopAndInsert")
        recordingGeneration += 1
        let generation = recordingGeneration
        state = .stopping
        task?.cancel()
        task = Task { [weak self, generation] in
            guard let self else { return }
            let text = await self.service.stopListening()
            guard self.recordingGeneration == generation else { return }
            MacVoiceInputLog.write("controller.stopAndInsert final length=\(text.count), text='\(Self.preview(text))'")
            self.emitTranscriptionDelta(text)
            self.state = .idle
            self.previewLabel.isHidden = true
        }
    }

    private func emitTranscriptionDelta(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != emittedTranscription else { return }

        let prefixEnd = normalized.commonPrefixEnd(with: emittedTranscription)
        let oldRemainder = emittedTranscription[prefixEnd.oldIndex...]
        let newRemainder = normalized[prefixEnd.newIndex...]

        let deletes = String(repeating: "\u{7f}", count: oldRemainder.count)
        let delta = deletes + String(newRemainder)
        guard !delta.isEmpty else {
            emittedTranscription = normalized
            return
        }

        MacVoiceInputLog.write("controller.emitDelta deleteCount=\(oldRemainder.count), insertCount=\(newRemainder.count), deltaPreview='\(Self.preview(delta))'")
        onTextReady(delta)
        emittedTranscription = normalized
    }

    private func showPreview(_ text: String, autoHide: Bool) {
        hidePreviewWorkItem?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            previewLabel.isHidden = true
            return
        }

        previewLabel.stringValue = trimmed
        previewLabel.isHidden = false
        previewLabel.needsLayout = true

        if autoHide {
            let item = DispatchWorkItem { [weak self] in
                self?.previewLabel.isHidden = true
            }
            hidePreviewWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
        }
    }

    private func updateAppearance() {
        let symbolName: String
        let fill: NSColor
        let tint: NSColor
        let border: NSColor
        let toolTip: String

        switch state {
        case .idle:
            symbolName = "mic.fill"
            fill = MacTheme.surfaceBase.withAlphaComponent(0.92)
            tint = MacTheme.accentBlue
            border = MacTheme.borderIdle
            toolTip = String(localized: "voice.mac.tooltip.start", defaultValue: "Start voice input")
        case .starting:
            symbolName = "mic.badge.plus"
            fill = MacTheme.accentAmber.withAlphaComponent(0.92)
            tint = MacTheme.surfaceDeep
            border = MacTheme.accentAmber
            toolTip = String(localized: "voice.mac.tooltip.starting", defaultValue: "Preparing voice input")
        case .recording:
            symbolName = "stop.fill"
            fill = MacTheme.accentRed.withAlphaComponent(0.92)
            tint = MacTheme.buttonTextOnAccent
            border = MacTheme.accentRed
            toolTip = String(localized: "voice.mac.tooltip.stop", defaultValue: "Stop and insert text")
        case .stopping:
            symbolName = "waveform"
            fill = MacTheme.accentBlue.withAlphaComponent(0.92)
            tint = MacTheme.buttonTextOnAccent
            border = MacTheme.accentBlue
            toolTip = String(localized: "voice.mac.tooltip.stopping", defaultValue: "Finishing transcription")
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        button.contentTintColor = tint
        button.toolTip = toolTip
        button.layer?.backgroundColor = fill.cgColor
        button.layer?.borderColor = border.withAlphaComponent(0.7).cgColor
        button.layer?.borderWidth = 1

        previewLabel.textColor = MacTheme.textPrimary
        previewLabel.layer?.backgroundColor = MacTheme.surfaceBase.withAlphaComponent(0.94).cgColor
        previewLabel.layer?.borderColor = MacTheme.borderIdle.withAlphaComponent(0.9).cgColor
        previewLabel.layer?.borderWidth = 1
    }

    private static func preview(_ text: String) -> String {
        String(text.prefix(160)).replacingOccurrences(of: "\n", with: "\\n")
    }
}

private final class VoicePreviewLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
    }
}

private final class VoiceButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private extension String {
    func commonPrefixEnd(with other: String) -> (newIndex: String.Index, oldIndex: String.Index) {
        var newIndex = startIndex
        var oldIndex = other.startIndex

        while newIndex < endIndex, oldIndex < other.endIndex, self[newIndex] == other[oldIndex] {
            newIndex = index(after: newIndex)
            oldIndex = other.index(after: oldIndex)
        }

        return (newIndex, oldIndex)
    }
}
