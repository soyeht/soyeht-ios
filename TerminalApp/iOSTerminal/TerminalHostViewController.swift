import UIKit
import SwiftTerm

// MARK: - Terminal Mode

enum TerminalMode {
    case ssh(SSHConnectionInfo)
    case websocket(String) // wsUrl
}

// MARK: - Terminal Host View Controller

final class TerminalHostViewController: UIViewController {
    private var activeTerminalView: TerminalView?
    private var mode: TerminalMode?
    private var isInScrollMode = false

    // Voice input
    private var voiceBar: VoiceBarView?
    private var recordingPanel: VoiceRecordingPanel?
    private var voiceState: VoiceInputState = .idle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: ColorTheme.active.backgroundHex) ?? SoyehtTheme.uiBgPrimary
        view.isOpaque = true

        NotificationCenter.default.addObserver(
            forName: .soyehtTerminalResumeLive, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isInScrollMode = false
            _ = self?.activeTerminalView?.becomeFirstResponder()
        }

        NotificationCenter.default.addObserver(
            forName: .soyehtScrollTmuxTapped, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isInScrollMode = true
            _ = self?.activeTerminalView?.resignFirstResponder()
        }

        NotificationCenter.default.addObserver(
            forName: .soyehtFontSizeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            let size = TerminalPreferences.shared.fontSize
            self?.activeTerminalView?.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        NotificationCenter.default.addObserver(
            forName: .soyehtCursorStyleChanged, object: nil, queue: .main
        ) { [weak self] _ in
            if let style = CursorStyle.from(string: TerminalPreferences.shared.cursorStyle) {
                self?.activeTerminalView?.getTerminal().setCursorStyle(style)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .soyehtCursorColorChanged, object: nil, queue: .main
        ) { [weak self] _ in
            if let color = UIColor(hex: TerminalPreferences.shared.cursorColorHex) {
                self?.activeTerminalView?.caretColor = color
            }
        }

        NotificationCenter.default.addObserver(
            forName: .soyehtColorThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let tv = self?.activeTerminalView else { return }
            SoyehtTerminalAppearance.apply(to: tv)
            self?.view.backgroundColor = UIColor(hex: ColorTheme.active.backgroundHex)
                ?? SoyehtTheme.uiBgPrimary
        }

        NotificationCenter.default.addObserver(
            forName: .soyehtVoiceInputSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            if #available(iOS 26, *) {
                self?.updateVoiceBarVisibility()
            }
        }

        if let mode = self.mode {
            setupTerminal(mode: mode)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isInScrollMode {
            _ = activeTerminalView?.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        _ = activeTerminalView?.resignFirstResponder()
    }

    // MARK: - Configuration

    func updateConnectionInfo(_ info: SSHConnectionInfo) {
        let newMode = TerminalMode.ssh(info)
        if case .ssh(let existing) = mode, existing == info { return }
        mode = newMode
        if isViewLoaded { setupTerminal(mode: newMode) }
    }

    func updateWebSocket(_ wsUrl: String) {
        if case .websocket(let existing) = mode, existing == wsUrl { return }
        let newMode = TerminalMode.websocket(wsUrl)
        mode = newMode
        if isViewLoaded { setupTerminal(mode: newMode) }
    }

    // MARK: - Setup

    private func setupTerminal(mode: TerminalMode) {
        activeTerminalView?.removeFromSuperview()

        let terminalView: TerminalView
        switch mode {
        case .ssh(let info):
            let sshView = SshTerminalView(frame: .zero)
            sshView.configure(connectionInfo: info)
            terminalView = sshView

        case .websocket(let wsUrl):
            let wsView = WebSocketTerminalView(frame: .zero)
            wsView.onConnectionFailed = { _ in
                NotificationCenter.default.post(name: .soyehtConnectionLost, object: nil)
            }
            wsView.configure(wsUrl: wsUrl)
            terminalView = wsView
        }

        SoyehtTerminalAppearance.apply(to: terminalView)
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true
        terminalView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        terminalView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true

        view.keyboardLayoutGuide.topAnchor.constraint(equalTo: terminalView.bottomAnchor).isActive = true

        // Custom key bar + voice bar as inputAccessoryView
        let keyBar = SoyehtKeyBarView(
            frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44),
            terminalView: terminalView
        )

        if #available(iOS 26, *), TerminalPreferences.shared.voiceInputEnabled {
            let bar = VoiceBarView(frame: CGRect(x: 0, y: 44, width: view.bounds.width, height: 44))
            bar.autoresizingMask = [.flexibleWidth]
            bar.delegate = self
            self.voiceBar = bar

            let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 88))
            container.autoresizingMask = [.flexibleWidth]
            keyBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
            keyBar.autoresizingMask = [.flexibleWidth]
            container.addSubview(keyBar)
            container.addSubview(bar)
            terminalView.inputAccessoryView = container
        } else {
            terminalView.inputAccessoryView = keyBar
        }

        // Haptic feedback for iOS virtual keyboard
        terminalView.onSoftKeyboardInput = {
            HapticEngine.shared.play(zone: .alphanumeric)
        }

        // Horizontal swipe to switch tmux panes
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handlePaneSwipe(_:)))
        swipeLeft.direction = .left
        swipeLeft.delegate = self

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handlePaneSwipe(_:)))
        swipeRight.direction = .right
        swipeRight.delegate = self

        terminalView.addGestureRecognizer(swipeLeft)
        terminalView.addGestureRecognizer(swipeRight)

        activeTerminalView = terminalView
        if !isInScrollMode {
            _ = terminalView.becomeFirstResponder()
        }
    }

    @objc private func handlePaneSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard let tv = activeTerminalView, !tv.hasActiveSelection else { return }
        HapticEngine.shared.play(for: "paneSwipe")
        let name: Notification.Name = gesture.direction == .left
            ? .soyehtSwipePaneNext : .soyehtSwipePanePrev
        NotificationCenter.default.post(name: name, object: nil)
    }
}

// MARK: - Gesture Delegate

extension TerminalHostViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UISwipeGestureRecognizer
    }
}

// MARK: - Voice Input

@available(iOS 26, *)
extension TerminalHostViewController: VoiceBarViewDelegate, VoiceRecordingPanelDelegate, VoiceInputDelegate {

    // MARK: VoiceBarViewDelegate

    func voiceBarDidTap(_ bar: VoiceBarView) {
        // If already recording, ignore
        guard voiceState == .idle else { return }

        // Check permissions — on first use, just request and return
        let micStatus = VoicePermissionHelper.microphoneStatus()
        let speechStatus = VoicePermissionHelper.speechRecognitionStatus()

        if micStatus == .notDetermined || speechStatus == .notDetermined {
            Task {
                let result = await VoicePermissionHelper.requestAllPermissions()
                if !result.mic || !result.speech {
                    await MainActor.run { self.handlePermissionDenied() }
                }
                // Permissions granted — user can tap again to record
            }
            return
        }

        if micStatus != .granted || speechStatus != .granted {
            handlePermissionDenied()
            return
        }

        // Permissions OK — start recording
        voiceState = .recording
        HapticEngine.shared.play(for: "voiceRecord")
        beginRecording()
    }

    // MARK: VoiceRecordingPanelDelegate

    func recordingPanelDidTapSend(_ panel: VoiceRecordingPanel) {
        finishAndSend()
    }

    func recordingPanelDidTapCancel(_ panel: VoiceRecordingPanel) {
        cancelRecording()
    }

    // MARK: VoiceInputDelegate

    func voiceInputStateDidChange(_ state: VoiceInputState) {
        voiceState = state
    }

    func voiceInputDidUpdateTranscription(_ text: String) {
        recordingPanel?.updateTranscription(text)
    }

    func voiceInputDidUpdateAudioLevel(_ level: Float) {
        recordingPanel?.waveformView.updateLevel(level)
    }

    func voiceInputDidProduceText(_ text: String) {
        guard !text.isEmpty else { return }
        let terminalText = text.replacingOccurrences(of: "\n", with: "\r")
        activeTerminalView?.send(txt: terminalText)
    }

    func voiceInputDidFail(_ error: String) {
        dismissRecordingPanel()
        voiceState = .idle
    }

    // MARK: Private Voice Helpers

    private func beginRecording() {
        _ = activeTerminalView?.resignFirstResponder()

        let panel = VoiceRecordingPanel(frame: view.bounds)
        panel.delegate = self
        panel.alpha = 0
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.heightAnchor.constraint(equalToConstant: 320),
        ])

        recordingPanel = panel

        UIView.animate(withDuration: 0.25) {
            panel.alpha = 1
        }

        VoiceInputService.shared.delegate = self
        Task {
            do {
                try await VoiceInputService.shared.startListening()
            } catch {
                await MainActor.run {
                    self.voiceInputDidFail(error.localizedDescription)
                }
            }
        }
    }

    private func finishAndSend() {
        Task {
            let text = await VoiceInputService.shared.stopListening()
            await MainActor.run {
                self.voiceInputDidProduceText(text)
                self.dismissRecordingPanel()
                HapticEngine.shared.play(for: "voiceSend")
            }
        }
    }

    private func cancelRecording() {
        Task {
            await VoiceInputService.shared.cancelListening()
            await MainActor.run {
                self.dismissRecordingPanel()
                self.voiceState = .idle
            }
        }
    }

    private func dismissRecordingPanel() {
        voiceState = .idle
        recordingPanel?.stopTimers()
        UIView.animate(withDuration: 0.25, animations: {
            self.recordingPanel?.alpha = 0
        }, completion: { _ in
            self.recordingPanel?.removeFromSuperview()
            self.recordingPanel = nil
            if !self.isInScrollMode {
                _ = self.activeTerminalView?.becomeFirstResponder()
            }
        })
    }

    private func handlePermissionDenied() {
        voiceState = .idle
        let original = voiceBar?.backgroundColor
        UIView.animate(withDuration: 0.15, animations: {
            self.voiceBar?.backgroundColor = SoyehtTheme.uiBgKill
        }, completion: { _ in
            UIView.animate(withDuration: 0.3) {
                self.voiceBar?.backgroundColor = original
            }
        })
    }

    func updateVoiceBarVisibility() {
        if #available(iOS 26, *) {
            let shouldShow = TerminalPreferences.shared.voiceInputEnabled
            UIView.animate(withDuration: 0.25) {
                self.voiceBar?.isHidden = !shouldShow
            }
        }
    }
}

// MARK: - Custom Key Bar

final class SoyehtKeyBarView: UIView {
    private static let preferredHeight: CGFloat = 44

    weak var terminalView: TerminalView?

    private var repeatTimer: Timer?
    private var repeatTask: Task<(), Never>?

    private var isCtrlActive = false
    private var isAltActive = false
    private var ctrlButton: UIButton?
    private var altButton: UIButton?

    init(frame: CGRect, terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame)
        backgroundColor = SoyehtTheme.uiBgKeybarFrame
        setupButtons()

        NotificationCenter.default.addObserver(
            self, selector: #selector(ctrlModifierReset),
            name: .terminalViewControlModifierReset, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(metaModifierReset),
            name: .terminalViewMetaModifierReset, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    // MARK: - Layout

    private func setupButtons() {
        // Top border
        let topBorder = UIView()
        topBorder.backgroundColor = SoyehtTheme.uiTopBorder
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        // Horizontal scroll view for buttons
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInset.right = 110 // space so Kill/Enter can scroll clear of scroll tmux
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Button stack inside scroll view
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.frameLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.frameLayoutGuide.bottomAnchor),
        ])

        // 1. S-Tab
        stack.addArrangedSubview(makeButton(title: "S-Tab", action: #selector(shiftTabTapped)))
        // 2. /
        stack.addArrangedSubview(makeButton(title: "/", action: #selector(slashTapped)))
        // 3. Divider
        stack.addArrangedSubview(makeDivider())
        // 4. Tab
        stack.addArrangedSubview(makeButton(title: "Tab", action: #selector(tabTapped)))
        // 5. Esc
        stack.addArrangedSubview(makeButton(title: "Esc", action: #selector(escTapped)))
        // 6. Divider
        stack.addArrangedSubview(makeDivider())
        // 7-10. Arrows
        stack.addArrangedSubview(makeArrowButton(icon: "chevron.up", action: #selector(upTapped)))
        stack.addArrangedSubview(makeArrowButton(icon: "chevron.down", action: #selector(downTapped)))
        stack.addArrangedSubview(makeArrowButton(icon: "chevron.left", action: #selector(leftTapped)))
        stack.addArrangedSubview(makeArrowButton(icon: "chevron.right", action: #selector(rightTapped)))
        // 11. Divider
        stack.addArrangedSubview(makeDivider())
        // PgUp / PgDn
        stack.addArrangedSubview(makeButton(title: "PgUp", action: #selector(pageUpTapped)))
        stack.addArrangedSubview(makeButton(title: "PgDn", action: #selector(pageDownTapped)))
        // Divider
        stack.addArrangedSubview(makeDivider())
        // 12. Ctrl
        let ctrlBtn = makeModifierButton(title: "Ctrl", action: #selector(ctrlTapped))
        self.ctrlButton = ctrlBtn
        stack.addArrangedSubview(ctrlBtn)
        // 13. Alt
        let altBtn = makeModifierButton(title: "Alt", action: #selector(altTapped))
        self.altButton = altBtn
        stack.addArrangedSubview(altBtn)
        // 14. Divider
        stack.addArrangedSubview(makeDivider())
        // 15. Kill (red)
        let killBtn = makeButton(title: "Kill", action: #selector(killTapped))
        killBtn.setTitleColor(SoyehtTheme.uiKillRed, for: .normal)
        killBtn.backgroundColor = SoyehtTheme.uiBgKill
        killBtn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        stack.addArrangedSubview(killBtn)
        // 16. Enter (green)
        let enterBtn = makeButton(title: "Enter", action: #selector(enterTapped))
        enterBtn.setTitleColor(SoyehtTheme.uiEnterGreen, for: .normal)
        enterBtn.backgroundColor = SoyehtTheme.uiBgEnter
        enterBtn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        stack.addArrangedSubview(enterBtn)

        // Scroll tmux — floating with opaque backing so buttons don't show through
        let scrollBtnContainer = UIView()
        scrollBtnContainer.backgroundColor = SoyehtTheme.uiBgKeybarFrame
        scrollBtnContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollBtnContainer)
        scrollBtnContainer.layer.zPosition = 10

        // Gradient fade on leading edge of container
        let gradientView = GradientMaskView()
        gradientView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gradientView)
        gradientView.layer.zPosition = 9

        let scrollBtn = UIButton(type: .system)
        scrollBtn.setTitle("history", for: .normal)
        scrollBtn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        scrollBtn.setTitleColor(SoyehtTheme.uiScrollBtnBorder, for: .normal)
        scrollBtn.backgroundColor = SoyehtTheme.uiScrollBtnBg
        scrollBtn.layer.cornerRadius = 0
        scrollBtn.layer.borderWidth = 1
        scrollBtn.layer.borderColor = SoyehtTheme.uiScrollBtnBorder.cgColor
        scrollBtn.addTarget(self, action: #selector(scrollTmuxTapped), for: .touchUpInside)
        scrollBtn.translatesAutoresizingMaskIntoConstraints = false
        var scrollBtnConfig = UIButton.Configuration.plain()
        scrollBtnConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        scrollBtn.configuration = scrollBtnConfig
        scrollBtnContainer.addSubview(scrollBtn)

        NSLayoutConstraint.activate([
            // Opaque backing: fills from scroll button leading edge to trailing edge
            scrollBtnContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollBtnContainer.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            scrollBtnContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Gradient fade to the left of the opaque container
            gradientView.trailingAnchor.constraint(equalTo: scrollBtnContainer.leadingAnchor),
            gradientView.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            gradientView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gradientView.widthAnchor.constraint(equalToConstant: 16),

            // Scroll button inside container
            scrollBtn.leadingAnchor.constraint(equalTo: scrollBtnContainer.leadingAnchor, constant: 4),
            scrollBtn.trailingAnchor.constraint(equalTo: scrollBtnContainer.trailingAnchor, constant: -6),
            scrollBtn.centerYAnchor.constraint(equalTo: scrollBtnContainer.centerYAnchor),
            scrollBtn.heightAnchor.constraint(equalToConstant: 32),
            scrollBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    // MARK: - Factory Methods

    private func makeButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        btn.setTitleColor(SoyehtTheme.uiTextButton, for: .normal)
        btn.backgroundColor = SoyehtTheme.uiBgButton
        btn.layer.cornerRadius = 0
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        var btnConfig = UIButton.Configuration.plain()
        btnConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9)
        btn.configuration = btnConfig
        return btn
    }

    private func makeArrowButton(icon: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        btn.setImage(
            UIImage(systemName: icon, withConfiguration: config)?
                .withTintColor(SoyehtTheme.uiTextButton, renderingMode: .alwaysOriginal),
            for: .normal
        )
        btn.backgroundColor = SoyehtTheme.uiBgButton
        btn.layer.cornerRadius = 0
        btn.addTarget(self, action: action, for: .touchDown)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchUpInside)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchUpOutside)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchCancel)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 48).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return btn
    }

    private func makeModifierButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        btn.setTitleColor(SoyehtTheme.uiTextButton, for: .normal)
        btn.backgroundColor = SoyehtTheme.uiBgButton
        btn.layer.cornerRadius = 0
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        var modConfig = UIButton.Configuration.plain()
        modConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9)
        btn.configuration = modConfig
        return btn
    }

    private func makeDivider() -> UIView {
        let div = UIView()
        div.backgroundColor = SoyehtTheme.uiDivider
        div.translatesAutoresizingMaskIntoConstraints = false
        div.widthAnchor.constraint(equalToConstant: 1).isActive = true
        div.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return div
    }

    // MARK: - Haptic + Send

    private func clickAndSend(_ data: [UInt8], key: String) {
        HapticEngine.shared.play(for: key)
        terminalView?.send(data)
    }

    // MARK: - Button Actions

    @objc private func shiftTabTapped() {
        clickAndSend(EscapeSequences.cmdBackTab, key: "S-Tab")
    }

    @objc private func slashTapped() {
        clickAndSend([0x2f], key: "/")
    }

    @objc private func tabTapped() { clickAndSend([0x9], key: "Tab") }
    @objc private func escTapped() { clickAndSend([0x1b], key: "Esc") }
    @objc private func killTapped() { clickAndSend([0x03], key: "Kill") }
    @objc private func enterTapped() { clickAndSend([0x0d], key: "Enter") }

    @objc private func pageUpTapped() {
        clickAndSend(EscapeSequences.cmdPageUp, key: "PgUp")
    }

    @objc private func pageDownTapped() {
        clickAndSend(EscapeSequences.cmdPageDown, key: "PgDn")
    }

    @objc private func scrollTmuxTapped() {
        HapticEngine.shared.play(for: "scrollTmux")
        NotificationCenter.default.post(name: .soyehtScrollTmuxTapped, object: nil)
    }

    // MARK: - Modifier Toggles

    @objc private func ctrlTapped() {
        HapticEngine.shared.play(for: "Ctrl")
        isCtrlActive.toggle()
        terminalView?.controlModifier = isCtrlActive
        updateModifierAppearance(ctrlButton, active: isCtrlActive)
    }

    @objc private func altTapped() {
        HapticEngine.shared.play(for: "Alt")
        isAltActive.toggle()
        terminalView?.metaModifier = isAltActive
        updateModifierAppearance(altButton, active: isAltActive)
    }

    @objc private func ctrlModifierReset() {
        isCtrlActive = false
        updateModifierAppearance(ctrlButton, active: false)
    }

    @objc private func metaModifierReset() {
        isAltActive = false
        updateModifierAppearance(altButton, active: false)
    }

    private func updateModifierAppearance(_ button: UIButton?, active: Bool) {
        guard let button else { return }
        if active {
            button.backgroundColor = SoyehtTheme.uiAccentGreen
            button.setTitleColor(SoyehtTheme.uiBgPrimary, for: .normal)
        } else {
            button.backgroundColor = SoyehtTheme.uiBgButton
            button.setTitleColor(SoyehtTheme.uiTextButton, for: .normal)
        }
    }

    // MARK: - Arrow Auto-Repeat

    private func startRepeat(hapticKey: String, _ action: @escaping () -> Void) {
        HapticEngine.shared.play(for: hapticKey)
        action()
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !(repeatTask?.isCancelled ?? true) else { return }
            await MainActor.run {
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    HapticEngine.shared.play(for: hapticKey)
                    action()
                }
            }
        }
    }

    private func sendArrow(_ label: String) {
        guard let tv = terminalView else { return }
        let seq = KeyBarConfiguration.arrowSequence(
            for: label,
            applicationCursor: tv.getTerminal().applicationCursor
        )
        tv.send(seq)
    }

    @objc private func upTapped() {
        startRepeat(hapticKey: "↑") { [weak self] in self?.sendArrow("↑") }
    }
    @objc private func downTapped() {
        startRepeat(hapticKey: "↓") { [weak self] in self?.sendArrow("↓") }
    }
    @objc private func leftTapped() {
        startRepeat(hapticKey: "←") { [weak self] in self?.sendArrow("←") }
    }
    @objc private func rightTapped() {
        startRepeat(hapticKey: "→") { [weak self] in self?.sendArrow("→") }
    }

    @objc private func cancelRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatTask?.cancel()
        repeatTask = nil
    }
}

// MARK: - Gradient Fade View

/// Draws a horizontal gradient from clear (left) to keybar background (right).
/// Used to smoothly fade buttons as they scroll under the scroll tmux area.
private final class GradientMaskView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            SoyehtTheme.uiBgKeybarFrame.withAlphaComponent(0).cgColor,
            SoyehtTheme.uiBgKeybarFrame.cgColor,
        ]
    }
}
