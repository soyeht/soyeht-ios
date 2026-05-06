import UIKit
import SoyehtCore
import SwiftTerm

// MARK: - Terminal Mode

enum TerminalMode {
    case ssh(SSHConnectionInfo)
    case websocket(String) // wsUrl
}

// MARK: - Terminal Host View Controller

// Explicit `@MainActor` — see `ViewController.swift` for the rationale.
@MainActor
final class TerminalHostViewController: UIViewController {
    private var activeTerminalView: TerminalView?
    private var mode: TerminalMode?
    private var isInScrollMode = false
    private var notificationObservers: [NSObjectProtocol] = []

    var onFileBrowserRequested: (() -> Void)?

    // Voice input
    private var voiceBar: VoiceBarView?
    private var recordingPanel: VoiceRecordingPanel?
    private var voiceState: VoiceInputState = .idle

    // Attachment
    private(set) var attachmentCoordinator: TerminalAttachmentCoordinator?
    private var pendingAttachmentContainer: String?
    private var pendingAttachmentSession: String?
    private var pendingAttachmentContext: ServerContext?
    private var attachmentContainer: String?
    private var attachmentSession: String?
    private var attachmentContext: ServerContext?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SoyehtTheme.uiBgPrimary
        view.isOpaque = true

        installNotificationObservers()

        if let mode = self.mode {
            setupTerminal(mode: mode)
        }
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
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

    /// For Fase 2 attach URLs: called by `WebSocketTerminalView` before each
    /// reconnect attempt to obtain a fresh single-use attach nonce. Without
    /// this, `policyViolation` rejects every retry. Wired via the SwiftUI
    /// bridge `WebSocketTerminalRepresentable`.
    var attachURLRefresher: (@MainActor () async throws -> String)? {
        didSet {
            if let wsView = activeTerminalView as? WebSocketTerminalView {
                wsView.attachURLRefresher = attachURLRefresher
            }
        }
    }

    func updateAttachmentContext(container: String, session: String, serverContext: ServerContext) {
        attachmentContainer = container
        attachmentSession = session
        attachmentContext = serverContext
        if let coordinator = attachmentCoordinator {
            coordinator.container = container
            coordinator.sessionName = session
            coordinator.context = serverContext
        } else {
            pendingAttachmentContainer = container
            pendingAttachmentSession = session
            pendingAttachmentContext = serverContext
        }
    }

    // MARK: - Setup

    private func installNotificationObservers() {
        let center = NotificationCenter.default

        notificationObservers.append(center.addObserver(
            forName: .soyehtTerminalResumeLive, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isInScrollMode = false
            _ = self?.activeTerminalView?.becomeFirstResponder()
        })

        notificationObservers.append(center.addObserver(
            forName: .soyehtFontSizeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let tv = self?.activeTerminalView else { return }
            SoyehtTerminalAppearance.apply(to: tv)
        })

        notificationObservers.append(center.addObserver(
            forName: .soyehtCursorStyleChanged, object: nil, queue: .main
        ) { [weak self] _ in
            if let style = CursorStyle.from(string: TerminalPreferences.shared.cursorStyle) {
                self?.activeTerminalView?.getTerminal().setCursorStyle(style)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: .soyehtCursorColorChanged, object: nil, queue: .main
        ) { [weak self] _ in
            if let color = UIColor(hex: TerminalPreferences.shared.cursorColorHex) {
                self?.activeTerminalView?.caretColor = color
            }
        })

        notificationObservers.append(center.addObserver(
            forName: .soyehtColorThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let tv = self?.activeTerminalView else { return }
            SoyehtTerminalAppearance.apply(to: tv)
            self?.view.backgroundColor = SoyehtTheme.uiBgPrimary
            self?.view.window?.overrideUserInterfaceStyle = SoyehtTheme.userInterfaceStyle
            self?.setNeedsStatusBarAppearanceUpdate()
        })

        notificationObservers.append(center.addObserver(
            forName: .soyehtVoiceInputSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            if #available(iOS 26, *) {
                self?.updateVoiceBarVisibility()
            }
        })

        notificationObservers.append(center.addObserver(
            forName: .soyehtInsertIntoTerminal, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInsertIntoTerminal(note)
        })
    }

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
            wsView.attachURLRefresher = attachURLRefresher
            wsView.configure(wsUrl: wsUrl)
            terminalView = wsView
        }

        SoyehtTerminalAppearance.apply(to: terminalView)
        terminalView.accessibilityIdentifier = AccessibilityID.Terminal.terminalView
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true
        terminalView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        terminalView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true

        view.keyboardLayoutGuide.topAnchor.constraint(equalTo: terminalView.bottomAnchor).isActive = true

        // Attachment coordinator
        let coordinator = TerminalAttachmentCoordinator()
        coordinator.hostController = self
        coordinator.terminalView = terminalView
        if let c = pendingAttachmentContainer, let s = pendingAttachmentSession {
            coordinator.container = c
            coordinator.sessionName = s
            coordinator.context = pendingAttachmentContext
            pendingAttachmentContainer = nil
            pendingAttachmentSession = nil
            pendingAttachmentContext = nil
        }
        self.attachmentCoordinator = coordinator

        // Custom key bar + voice bar as inputAccessoryView
        let keyBar = SoyehtKeyBarView(
            frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44),
            terminalView: terminalView
        )
        keyBar.onAttachmentTapped = { [weak coordinator] in
            coordinator?.togglePicker()
        }
        keyBar.onFileBrowserTapped = { [weak self] in
            self?.onFileBrowserRequested?()
        }

        if #available(iOS 26, *), TerminalPreferences.shared.voiceInputEnabled {
            let bar = VoiceBarView(frame: CGRect(x: 0, y: 44, width: view.bounds.width, height: 44))
            bar.autoresizingMask = [.flexibleWidth]
            bar.accessibilityIdentifier = AccessibilityID.Terminal.voiceBar
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

        activeTerminalView = terminalView

        if !isInScrollMode {
            _ = terminalView.becomeFirstResponder()
        }
    }

    private func handleInsertIntoTerminal(_ note: Notification) {
        guard let text = note.userInfo?[SoyehtNotificationKey.text] as? String, !text.isEmpty else {
            return
        }

        let targetContainer = note.userInfo?[SoyehtNotificationKey.container] as? String
        let targetSession = note.userInfo?[SoyehtNotificationKey.session] as? String
        if let targetContainer, let attachmentContainer, targetContainer != attachmentContainer {
            return
        }
        if let targetSession, let attachmentSession, targetSession != attachmentSession {
            return
        }

        let bracketedPaste = "\u{001B}[200~" + text + "\u{001B}[201~"
        activeTerminalView?.send(txt: bracketedPaste)
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

    @available(iOS 26, *)
    func updateVoiceBarVisibility() {
        let shouldShow = TerminalPreferences.shared.voiceInputEnabled
        UIView.animate(withDuration: 0.25) {
            self.voiceBar?.isHidden = !shouldShow
        }
    }
}

// MARK: - Custom Key Bar

final class SoyehtKeyBarView: UIView {
    private static let preferredHeight: CGFloat = 44

    weak var terminalView: TerminalView?

    var onAttachmentTapped: (() -> Void)?
    var onFileBrowserTapped: (() -> Void)?

    private var repeatTimer: Timer?
    private var repeatTask: Task<(), Never>?

    private var isCtrlActive = false
    private var isAltActive = false
    private var ctrlButton: UIButton?
    private var altButton: UIButton?

    /// The button stack is retained so we can clear and re-populate it on config changes.
    private var buttonStack: UIStackView?

    /// Associated object keys for storing item data on UIButtons.
    private static var bytesKey: UInt8 = 0
    private static var hapticLabelKey: UInt8 = 1
    private static var arrowLabelKey: UInt8 = 2

    init(frame: CGRect, terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame)
        backgroundColor = SoyehtTheme.uiBgKeybarFrame
        setupChrome()
        populateButtons(from: TerminalPreferences.shared.resolvedActiveItems())

        NotificationCenter.default.addObserver(
            self, selector: #selector(ctrlModifierReset),
            name: .terminalViewControlModifierReset, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(metaModifierReset),
            name: .terminalViewMetaModifierReset, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildButtons),
            name: .soyehtShortcutBarChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .soyehtColorThemeChanged, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    // MARK: - Chrome (one-time layout)

    private func setupChrome() {
        // Top border
        let topBorder = UIView()
        topBorder.backgroundColor = SoyehtTheme.uiTopBorder
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        topBorder.tag = 900
        addSubview(topBorder)

        // Horizontal scroll view for buttons
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInset.right = 110
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
        self.buttonStack = stack

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
    }

    // MARK: - Data-Driven Button Population

    @objc private func rebuildButtons() {
        populateButtons(from: TerminalPreferences.shared.resolvedActiveItems())
    }

    @objc private func themeChanged() {
        applyTheme()
    }

    func applyTheme() {
        let wasCtrlActive = isCtrlActive
        let wasAltActive = isAltActive
        backgroundColor = SoyehtTheme.uiBgKeybarFrame
        viewWithTag(900)?.backgroundColor = SoyehtTheme.uiTopBorder
        populateButtons(from: TerminalPreferences.shared.resolvedActiveItems())
        isCtrlActive = wasCtrlActive
        isAltActive = wasAltActive
        terminalView?.controlModifier = wasCtrlActive
        terminalView?.metaModifier = wasAltActive
        updateModifierAppearance(ctrlButton, active: wasCtrlActive)
        updateModifierAppearance(altButton, active: wasAltActive)
    }

    private func populateButtons(from items: [ShortcutBarItem]) {
        guard let stack = buttonStack else { return }

        // Clear existing buttons
        cancelRepeat()
        ctrlButton = nil
        altButton = nil
        isCtrlActive = false
        isAltActive = false
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Paperclip attachment button (always first)
        let clipBtn = UIButton(type: .system)
        let clipImage = UIImage(systemName: "paperclip", withConfiguration: UIImage.SymbolConfiguration(pointSize: Typography.iconMediumPointSize, weight: .medium))
        clipBtn.setImage(clipImage, for: .normal)
        clipBtn.tintColor = SoyehtTheme.uiEnterGreen
        clipBtn.backgroundColor = SoyehtTheme.uiScrollBtnBg
        clipBtn.translatesAutoresizingMaskIntoConstraints = false
        clipBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        clipBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        var clipConfig = UIButton.Configuration.plain()
        clipConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
        clipBtn.configuration = clipConfig
        clipBtn.accessibilityIdentifier = AccessibilityID.Terminal.attachmentButton
        clipBtn.addTarget(self, action: #selector(attachmentTapped), for: .touchUpInside)
        stack.addArrangedSubview(clipBtn)

        let fileBrowserButton = UIButton(type: .system)
        let fileImage = UIImage(
            systemName: "folder",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Typography.iconMediumPointSize, weight: .medium)
        )
        fileBrowserButton.setImage(fileImage, for: .normal)
        fileBrowserButton.tintColor = SoyehtTheme.uiEnterGreen
        fileBrowserButton.backgroundColor = SoyehtTheme.uiScrollBtnBg
        fileBrowserButton.translatesAutoresizingMaskIntoConstraints = false
        fileBrowserButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        fileBrowserButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        var fileConfig = UIButton.Configuration.plain()
        fileConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
        fileBrowserButton.configuration = fileConfig
        fileBrowserButton.accessibilityIdentifier = AccessibilityID.Terminal.fileBrowserButton
        fileBrowserButton.addTarget(self, action: #selector(fileBrowserTapped), for: .touchUpInside)
        stack.addArrangedSubview(fileBrowserButton)
        stack.addArrangedSubview(makeDivider())

        // Add buttons with dividers between groups
        var lastGroup: ShortcutBarGroup? = nil
        for item in items {
            if let last = lastGroup, last != item.group {
                stack.addArrangedSubview(makeDivider())
            }
            lastGroup = item.group

            switch item.kind {
            case .arrow:
                let icon = arrowIcon(for: item.label)
                let btn = makeArrowButton(icon: icon, arrowLabel: item.label)
                btn.accessibilityIdentifier = AccessibilityID.Terminal.arrow(item.label)
                stack.addArrangedSubview(btn)

            case .modifierCtrl:
                let btn = makeModifierButton(title: item.label, action: #selector(ctrlTapped))
                btn.accessibilityIdentifier = AccessibilityID.Terminal.ctrlButton
                self.ctrlButton = btn
                stack.addArrangedSubview(btn)

            case .modifierAlt:
                let btn = makeModifierButton(title: item.label, action: #selector(altTapped))
                btn.accessibilityIdentifier = AccessibilityID.Terminal.altButton
                self.altButton = btn
                stack.addArrangedSubview(btn)

            case .send:
                let btn = makeSendButton(item: item)
                btn.accessibilityIdentifier = AccessibilityID.Terminal.shortcut(item.label)
                stack.addArrangedSubview(btn)
            }
        }
    }

    private func arrowIcon(for label: String) -> String {
        switch label {
        case "↑": return "chevron.up"
        case "↓": return "chevron.down"
        case "←": return "chevron.left"
        case "→": return "chevron.right"
        default:  return "chevron.right"
        }
    }

    // MARK: - Factory Methods

    private func makeSendButton(item: ShortcutBarItem) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(item.label, for: .normal)
        btn.titleLabel?.font = Typography.monoUIButton
        btn.layer.cornerRadius = 0
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        var btnConfig = UIButton.Configuration.plain()
        btnConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9)
        btn.configuration = btnConfig

        // Apply style colors
        switch item.style {
        case .danger:
            btn.setTitleColor(SoyehtTheme.uiKillRed, for: .normal)
            btn.backgroundColor = SoyehtTheme.uiBgKill
            btn.titleLabel?.font = Typography.monoUIButton
        case .action:
            btn.setTitleColor(SoyehtTheme.uiEnterGreen, for: .normal)
            btn.backgroundColor = SoyehtTheme.uiBgEnter
            btn.titleLabel?.font = Typography.monoUIButton
        case .default:
            btn.setTitleColor(SoyehtTheme.uiTextButton, for: .normal)
            btn.backgroundColor = SoyehtTheme.uiBgButton
        }

        // Store bytes and haptic label on the button
        objc_setAssociatedObject(btn, &Self.bytesKey, item.bytes, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(btn, &Self.hapticLabelKey, item.label, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        btn.addTarget(self, action: #selector(genericSendTapped(_:)), for: .touchUpInside)

        return btn
    }

    private func makeArrowButton(icon: String, arrowLabel: String) -> UIButton {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: Typography.iconActionPointSize, weight: .medium)
        btn.setImage(
            UIImage(systemName: icon, withConfiguration: config)?
                .withTintColor(SoyehtTheme.uiTextButton, renderingMode: .alwaysOriginal),
            for: .normal
        )
        btn.backgroundColor = SoyehtTheme.uiBgButton
        btn.layer.cornerRadius = 0
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 48).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        // Store arrow label for sendArrow lookup
        objc_setAssociatedObject(btn, &Self.arrowLabelKey, arrowLabel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        btn.addTarget(self, action: #selector(arrowTouchDown(_:)), for: .touchDown)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchUpInside)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchUpOutside)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchCancel)

        return btn
    }

    private func makeModifierButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = Typography.monoUIButton
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

    // MARK: - Generic Send Action

    @objc private func genericSendTapped(_ sender: UIButton) {
        guard let bytes = objc_getAssociatedObject(sender, &Self.bytesKey) as? [UInt8],
              let hapticLabel = objc_getAssociatedObject(sender, &Self.hapticLabelKey) as? String else { return }
        clickAndSend(bytes, key: hapticLabel)
    }

    // MARK: - Arrow Action

    @objc private func arrowTouchDown(_ sender: UIButton) {
        guard let label = objc_getAssociatedObject(sender, &Self.arrowLabelKey) as? String else { return }
        startRepeat(hapticKey: label) { [weak self] in self?.sendArrow(label) }
    }

    @objc private func attachmentTapped() {
        HapticEngine.shared.play(zone: .alphanumeric)
        onAttachmentTapped?()
    }

    @objc private func fileBrowserTapped() {
        HapticEngine.shared.play(zone: .alphanumeric)
        // Dismiss the software keyboard before presenting the browser. On device,
        // presenting the full-screen cover while the input accessory is active can
        // bounce the UI back to the session sheet instead of opening the browser.
        window?.endEditing(true)
        _ = terminalView?.resignFirstResponder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.onFileBrowserTapped?()
        }
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

    @objc private func cancelRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatTask?.cancel()
        repeatTask = nil
    }
}
