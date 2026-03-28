import UIKit
import SwiftTerm

// MARK: - Terminal Mode

enum TerminalMode {
    case ssh(SSHConnectionInfo)
    case websocket(String) // wsUrl
}

// MARK: - Soyeht Terminal Palette

private func c8(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
    SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
}

private let soyehtTerminalPalette: [SwiftTerm.Color] = [
    c8(0,   0,   0),       // 0  black
    c8(239, 68,  68),      // 1  red       (#EF4444)
    c8(0,   217, 163),     // 2  green     (#00D9A3)
    c8(245, 158, 11),      // 3  yellow    (#F59E0B)
    c8(3,   0,   178),     // 4  blue
    c8(178, 0,   178),     // 5  magenta
    c8(0,   165, 178),     // 6  cyan
    c8(229, 229, 229),     // 7  white
    c8(102, 102, 102),     // 8  bright black (#666666)
    c8(239, 68,  68),      // 9  bright red
    c8(0,   217, 163),     // 10 bright green (#00D9A3)
    c8(255, 170, 0),       // 11 bright yellow (#FFAA00)
    c8(7,   0,   254),     // 12 bright blue
    c8(229, 0,   229),     // 13 bright magenta
    c8(0,   229, 229),     // 14 bright cyan
    c8(255, 255, 255),     // 15 bright white
]

// MARK: - Terminal Host View Controller

final class TerminalHostViewController: UIViewController {
    private var activeTerminalView: TerminalView?
    private var mode: TerminalMode?
    private var isInScrollMode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SoyehtTheme.uiBgPrimary
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
            sshView.installColors(soyehtTerminalPalette)
            sshView.configure(connectionInfo: info)
            terminalView = sshView

        case .websocket(let wsUrl):
            let wsView = WebSocketTerminalView(frame: .zero)
            wsView.installColors(soyehtTerminalPalette)
            wsView.configure(wsUrl: wsUrl)
            terminalView = wsView
        }

        terminalView.isOpaque = true
        terminalView.backgroundColor = SoyehtTheme.uiBgPrimary
        terminalView.nativeForegroundColor = SoyehtTheme.uiTextPrimary
        terminalView.nativeBackgroundColor = SoyehtTheme.uiBgPrimary
        terminalView.caretColor = SoyehtTheme.uiAccentGreen
        terminalView.keyboardAppearance = .dark
        terminalView.allowMouseReporting = false
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
            terminalView: terminalView
        )
        terminalView.inputAccessoryView = keyBar

        activeTerminalView = terminalView
        if !isInScrollMode {
            _ = terminalView.becomeFirstResponder()
        }
    }
}

// MARK: - Custom Key Bar

final class SoyehtKeyBarView: UIView {
    private static let preferredHeight: CGFloat = 44

    weak var terminalView: TerminalView?

    private let haptic = UIImpactFeedbackGenerator(style: .light)
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

    private func clickAndSend(_ data: [UInt8]) {
        haptic.impactOccurred()

        terminalView?.send(data)
    }

    // MARK: - Button Actions

    @objc private func shiftTabTapped() {
        clickAndSend(EscapeSequences.cmdBackTab)
    }

    @objc private func slashTapped() {
        haptic.impactOccurred()

        terminalView?.send([0x2f])
    }

    @objc private func tabTapped() { clickAndSend([0x9]) }
    @objc private func escTapped() { clickAndSend([0x1b]) }
    @objc private func killTapped() { clickAndSend([0x03]) }
    @objc private func enterTapped() { clickAndSend([0x0d]) }

    @objc private func pageUpTapped() {
        clickAndSend(EscapeSequences.cmdPageUp)
    }

    @objc private func pageDownTapped() {
        clickAndSend(EscapeSequences.cmdPageDown)
    }

    @objc private func scrollTmuxTapped() {
        haptic.impactOccurred()

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
            button.setTitleColor(SoyehtTheme.uiBgPrimary, for: .normal)
        } else {
            button.backgroundColor = SoyehtTheme.uiBgButton
            button.setTitleColor(SoyehtTheme.uiTextButton, for: .normal)
        }
    }

    // MARK: - Arrow Auto-Repeat

    private func startRepeat(_ action: @escaping () -> Void) {
        haptic.impactOccurred()

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
