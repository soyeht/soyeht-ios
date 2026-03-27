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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true

        NotificationCenter.default.addObserver(
            forName: .soyehtTerminalResumeLive, object: nil, queue: .main
        ) { [weak self] _ in
            self?.activeTerminalView?.becomeFirstResponder()
        }

        if let mode = self.mode {
            setupTerminal(mode: mode)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activeTerminalView?.becomeFirstResponder()
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
            wsView.configure(wsUrl: wsUrl)
            terminalView = wsView
        }

        terminalView.isOpaque = true
        terminalView.backgroundColor = .black
        terminalView.nativeBackgroundColor = .black
        terminalView.keyboardAppearance = .dark
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true
        terminalView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        terminalView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true

        if #available(iOS 15.0, *) {
            view.keyboardLayoutGuide.topAnchor.constraint(equalTo: terminalView.bottomAnchor).isActive = true
        } else {
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        }

        // Custom key bar
        let keyBar = SoyehtKeyBarView(
            frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44),
            inputViewStyle: .keyboard,
            terminalView: terminalView
        )
        terminalView.inputAccessoryView = keyBar

        activeTerminalView = terminalView
        terminalView.becomeFirstResponder()
    }
}

// MARK: - Custom Key Bar

final class SoyehtKeyBarView: UIInputView, UIInputViewAudioFeedback {
    weak var terminalView: TerminalView?
    var enableInputClicksWhenVisible: Bool { true }

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var repeatTimer: Timer?
    private var repeatTask: Task<(), Never>?

    private var isCtrlActive = false
    private var isAltActive = false
    private var ctrlButton: UIButton?
    private var altButton: UIButton?

    init(frame: CGRect, inputViewStyle: UIInputView.Style, terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        allowsSelfSizing = true
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
        scrollBtn.setTitle("scroll tmux", for: .normal)
        scrollBtn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        scrollBtn.setTitleColor(SoyehtTheme.uiScrollBtnBorder, for: .normal)
        scrollBtn.backgroundColor = SoyehtTheme.uiScrollBtnBg
        scrollBtn.layer.cornerRadius = 0
        scrollBtn.layer.borderWidth = 1
        scrollBtn.layer.borderColor = SoyehtTheme.uiScrollBtnBorder.cgColor
        scrollBtn.addTarget(self, action: #selector(scrollTmuxTapped), for: .touchUpInside)
        scrollBtn.translatesAutoresizingMaskIntoConstraints = false
        scrollBtn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
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
        btn.addTarget(self, action: action, for: .touchDown)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
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
        btn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
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

    private func clickAndSend(_ data: [UInt8]) {
        haptic.impactOccurred()
        UIDevice.current.playInputClick()
        terminalView?.send(data)
    }

    // MARK: - Button Actions

    @objc private func shiftTabTapped() {
        clickAndSend(EscapeSequences.cmdBackTab)
    }

    @objc private func slashTapped() {
        haptic.impactOccurred()
        UIDevice.current.playInputClick()
        terminalView?.send([0x2f])
    }

    @objc private func tabTapped() { clickAndSend([0x9]) }
    @objc private func escTapped() { clickAndSend([0x1b]) }
    @objc private func killTapped() { clickAndSend([0x03]) }
    @objc private func enterTapped() { clickAndSend([0x0d]) }

    @objc private func scrollTmuxTapped() {
        haptic.impactOccurred()
        UIDevice.current.playInputClick()
        NotificationCenter.default.post(name: .soyehtScrollTmuxTapped, object: nil)
    }

    // MARK: - Modifier Toggles

    @objc private func ctrlTapped() {
        haptic.impactOccurred()
        isCtrlActive.toggle()
        terminalView?.controlModifier = isCtrlActive
        updateModifierAppearance(ctrlButton, active: isCtrlActive)
    }

    @objc private func altTapped() {
        haptic.impactOccurred()
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
            button.setTitleColor(.black, for: .normal)
        } else {
            button.backgroundColor = SoyehtTheme.uiBgButton
            button.setTitleColor(SoyehtTheme.uiTextButton, for: .normal)
        }
    }

    // MARK: - Arrow Auto-Repeat

    private func startRepeat(_ action: @escaping () -> Void) {
        haptic.impactOccurred()
        UIDevice.current.playInputClick()
        action()
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !(repeatTask?.isCancelled ?? true) else { return }
            await MainActor.run {
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    self?.haptic.impactOccurred()
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
        startRepeat { [weak self] in self?.sendArrow("↑") }
    }
    @objc private func downTapped() {
        startRepeat { [weak self] in self?.sendArrow("↓") }
    }
    @objc private func leftTapped() {
        startRepeat { [weak self] in self?.sendArrow("←") }
    }
    @objc private func rightTapped() {
        startRepeat { [weak self] in self?.sendArrow("→") }
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
