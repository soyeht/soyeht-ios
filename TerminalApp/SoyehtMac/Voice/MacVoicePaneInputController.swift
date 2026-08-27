import AppKit

@MainActor
protocol PaneVoiceInputControlling: AnyObject {
    func setVisible(_ visible: Bool)
    func applyTheme()
    func cancel()
    func startPushToTalk()
    func stopPushToTalk()
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
        /// Neo tucks the whole thing into the corner: the recess hangs mostly
        /// off the card, over the corridor, so it eats as little pane as
        /// possible. The gradient is what lets it — the inboard side arrives
        /// at the card's colour and vanishes into it.
        static let socketSize: CGFloat = 52
        static let socketTrailingInset: CGFloat = 3
        static let socketBottomInset: CGFloat = 2
        /// The card's radius is 20 on a large body; this is the same gesture
        /// at small scale. A disc would be the only round thing on a screen
        /// built from rounded rectangles.
        static let socketRadius: CGFloat = 13
        static let buttonRadius: CGFloat = 10
    }

    private weak var hostView: NSView?
    private let service = MacVoiceInputService()
    private let onTextReady: (String) -> Void

    private let button = VoiceButton()
    private let socket = VoiceSocketView(frame: .zero)
    private let previewLabel = VoicePreviewLabel(frame: .zero)
    private var buttonInsets: (trailing: NSLayoutConstraint, bottom: NSLayoutConstraint)?
    private var isPressed = false
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
        // The recess exists only for the button; it goes with it. `isHidden`
        // is set again by `updateAppearance` for the style, so this is the
        // visibility half only.
        socket.isHidden = !visible || MacSurface.style != .neomorphic
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

    func startPushToTalk() {
        switch state {
        case .idle:
            startRecording()
        case .starting, .recording, .stopping:
            break
        }
    }

    func stopPushToTalk() {
        switch state {
        case .idle, .stopping:
            break
        case .starting:
            cancel()
        case .recording:
            stopAndInsert()
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
        guard MacSurface.style == .neomorphic else {
            button.layer?.shadowOpacity =
                MacSurface.Shadows.voiceButton.opacity + Float(clamped * 0.34)
            return
        }
        // While recording the button is sunk and has no shadow to animate —
        // which is precisely when the level matters. It rides the glyph
        // instead, where it is visible over a terminal full of text; the old
        // one animated the opacity of a black drop shadow and was all but
        // invisible there.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.layer?.opacity = Float(0.62 + clamped * 0.38)
        CATransaction.commit()
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
        button.target = self
        button.action = #selector(toggleRecording)
        button.onPressedChanged = { [weak self] pressed in
            self?.isPressed = pressed
            self?.updateAppearance()
        }
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(String(localized: "voice.mac.button.a11y", defaultValue: "Voice input"))

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.isHidden = true
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = MacTypography.NSFonts.Text.monoBody
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        socket.translatesAutoresizingMaskIntoConstraints = false
        socket.isHidden = true

        hostView.addSubview(previewLabel)
        // The recess goes in first so the button draws inside it. Both are
        // permanent children of the host, never tied to each other by
        // constraints that a reparent could drop.
        hostView.addSubview(socket)
        hostView.addSubview(button)

        let trailing = button.trailingAnchor.constraint(
            equalTo: hostView.trailingAnchor, constant: -Layout.buttonTrailingInset)
        let bottom = button.bottomAnchor.constraint(
            equalTo: hostView.bottomAnchor, constant: -Layout.buttonBottomInset)
        buttonInsets = (trailing, bottom)

        NSLayoutConstraint.activate([
            trailing,
            bottom,
            button.widthAnchor.constraint(equalToConstant: Layout.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Layout.buttonSize),

            socket.trailingAnchor.constraint(equalTo: hostView.trailingAnchor,
                                             constant: -Layout.socketTrailingInset),
            socket.bottomAnchor.constraint(equalTo: hostView.bottomAnchor,
                                           constant: -Layout.socketBottomInset),
            socket.widthAnchor.constraint(equalToConstant: Layout.socketSize),
            socket.heightAnchor.constraint(equalToConstant: Layout.socketSize),

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
        button.toolTip = toolTip

        guard MacSurface.style == .neomorphic else {
            socket.isHidden = true
            buttonInsets?.trailing.constant = -Layout.buttonTrailingInset
            buttonInsets?.bottom.constant = -Layout.buttonBottomInset
            button.layer?.cornerRadius = MacSurface.Radius.card
            button.contentTintColor = tint
            button.layer?.backgroundColor = fill.cgColor
            button.layer?.borderColor = border.withAlphaComponent(0.7).cgColor
            button.layer?.borderWidth = MacSurface.Border.hairline
            MacSurface.Shadows.voiceButton.apply(to: button.layer)
            previewLabel.textColor = MacTheme.textPrimary
            previewLabel.layer?.backgroundColor = MacTheme.surfaceBase.withAlphaComponent(0.94).cgColor
            previewLabel.layer?.borderColor = MacTheme.borderIdle.withAlphaComponent(0.9).cgColor
            previewLabel.layer?.borderWidth = MacSurface.Border.hairline
            return
        }

        // Neo: the recess carries the separation, so the button carries none
        // of the old chrome. No border — depth does that here. No translucent
        // fill — it took its colour from whatever scrolled underneath. And the
        // tint follows the THEME's accent rather than the fixed brand blue,
        // which is the same defect the Claws button had.
        socket.isHidden = button.isHidden
        socket.applyTheme(cornerRadius: Layout.socketRadius)
        buttonInsets?.trailing.constant =
            -(Layout.socketTrailingInset + (Layout.socketSize - Layout.buttonSize) / 2)
        buttonInsets?.bottom.constant =
            -(Layout.socketBottomInset + (Layout.socketSize - Layout.buttonSize) / 2)
        button.layer?.cornerRadius = Layout.buttonRadius
        button.layer?.borderWidth = 0
        button.layer?.borderColor = nil

        // Lit on one side, like the recess around it: two contours close the
        // shape and put the button back on top of the pane instead of in it.
        let raised = MacSurface.Shadow.neo(
            color: MacTheme.neoShadowDark, offset: CGSize(width: 3, height: -3), blur: 7)
        switch state {
        case _ where isPressed:
            // Held down: sunk, whatever the state underneath. Pressing is the
            // one thing the user does here and it has to answer immediately;
            // the state change behind it waits on the voice service.
            button.layer?.backgroundColor = MacTheme.neoWell.cgColor
            button.contentTintColor = MacTheme.interactionAccent
            MacSurface.Shadow.clear(button.layer)
        case .idle, .starting:
            button.layer?.backgroundColor = MacTheme.neoSurface.cgColor
            button.contentTintColor = state == .idle
                ? MacTheme.interactionAccent
                : MacTheme.accentAmber
            raised.apply(to: button.layer)
        case .recording, .stopping:
            // Sinks into its own recess, and the danger colour is on the glyph
            // alone. It used to be a filled red disc — the only saturated
            // thing on screen, which is what the Claws button stopped doing.
            button.layer?.backgroundColor = MacTheme.neoWell.cgColor
            button.contentTintColor = state == .recording
                ? MacTheme.accentRed
                : MacTheme.interactionAccent
            MacSurface.Shadow.clear(button.layer)
        }

        previewLabel.textColor = MacTheme.textPrimary
        previewLabel.layer?.backgroundColor = MacTheme.surfaceBase.withAlphaComponent(0.94).cgColor
        previewLabel.layer?.borderColor = MacTheme.borderIdle.withAlphaComponent(0.9).cgColor
        previewLabel.layer?.borderWidth = MacSurface.Border.hairline
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
        layer?.cornerRadius = MacSurface.Radius.inputCapsule
        layer?.masksToBounds = true
    }
}

private final class VoiceButton: NSButton {
    /// Called on press and on release, so the owner can sink the button while
    /// the mouse is held. Without it the only feedback is the state changing
    /// to recording, which waits on the voice service starting — a gap where
    /// a click looks like it did nothing.
    var onPressedChanged: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onPressedChanged?(true)
        super.mouseDown(with: event)
        // `super.mouseDown` runs its own tracking loop and only returns once
        // the mouse is released, so this is the release.
        onPressedChanged?(false)
    }

    override func resetCursorRects() {
        MacCursor.claim(.pointingHand, on: self)
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

/// The recess the voice button sits in, under the neomorphic style.
///
/// The button belongs to no pane: it lives on an overlay pinned to the whole
/// window and draws above everything, so it lands across a card's rounded
/// corner with the corridor beside it. Half of it rested on the pane's colour
/// and half on the canvas, and being 62% translucent its own colour changed
/// with whatever scrolled underneath.
///
/// So it stops resting on anything. This carves a hole and the button sits in
/// it — the same move `GridLightingView` makes when it masks a card out of its
/// own shadow, inverted: there the shadow is cut, here the background is.
///
/// The hole is lit on ONE side. The shadow entering from the top-left, where
/// the light comes from everywhere else in this style, is what separates the
/// button from the pane. A matching rim on the opposite side closed the shape
/// into a second contour and handed the button back its pasted-on look, so
/// there is none. And the fill crosses from the canvas colour to the pane's
/// own, so on that far side there is no boundary left to see at all: the hole
/// simply stops existing where it does not need to divide.
@MainActor
private final class VoiceSocketView: NSView {
    private let fill = CAGradientLayer()
    private let recess = MacInnerWellShadowView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(fill)
        // 135 degrees: canvas at the top-left corner, the pane's own colour at
        // the bottom-right. In an unflipped layer that is (0,1) to (1,0).
        fill.startPoint = CGPoint(x: 0, y: 1)
        fill.endPoint = CGPoint(x: 1, y: 0)
        fill.locations = [0, 0.4, 0.96]
        recess.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recess)
        NSLayoutConstraint.activate([
            recess.leadingAnchor.constraint(equalTo: leadingAnchor),
            recess.trailingAnchor.constraint(equalTo: trailingAnchor),
            recess.topAnchor.constraint(equalTo: topAnchor),
            recess.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Decoration: the button it surrounds owns every click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme(cornerRadius: CGFloat) {
        let canvas = MacTheme.paneGridCanvas
        let face = MacTheme.neoSurface
        fill.colors = [canvas.cgColor, canvas.cgColor, face.cgColor]
        fill.cornerRadius = cornerRadius
        recess.applyStyle(
            cornerRadius: cornerRadius,
            dark: .neo(color: MacTheme.neoWellShadow,
                       offset: CGSize(width: 3, height: -3), blur: 7),
            // No rim. See the type comment: the second contour is what made
            // the button read as an object sitting on the pane.
            light: MacSurface.Shadow(color: .clear, opacity: 0, offset: .zero, radius: 0)
        )
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }
}
