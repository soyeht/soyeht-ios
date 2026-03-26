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

    private var controlModifier = false
    private var controlButton: UIButton?
    private var repeatTimer: Timer?
    private var repeatTask: Task<(), Never>?

    init(frame: CGRect, inputViewStyle: UIInputView.Style, terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        allowsSelfSizing = true
        backgroundColor = SoyehtTheme.uiBgKeybar
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupButtons() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        let tabBtn = makeButton(title: "Tab", action: #selector(tabTapped))
        let ctrlBtn = makeButton(title: "Ctrl", action: #selector(ctrlTapped))
        self.controlButton = ctrlBtn
        let escBtn = makeButton(title: "Esc", action: #selector(escTapped))

        stack.addArrangedSubview(tabBtn)
        stack.addArrangedSubview(ctrlBtn)
        stack.addArrangedSubview(escBtn)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let upBtn = makeArrowButton(icon: "chevron.up", action: #selector(upTapped))
        let downBtn = makeArrowButton(icon: "chevron.down", action: #selector(downTapped))
        let leftBtn = makeArrowButton(icon: "chevron.left", action: #selector(leftTapped))
        let rightBtn = makeArrowButton(icon: "chevron.right", action: #selector(rightTapped))

        stack.addArrangedSubview(leftBtn)
        stack.addArrangedSubview(downBtn)
        stack.addArrangedSubview(upBtn)
        stack.addArrangedSubview(rightBtn)

        let scrollBtn = UIButton(type: .system)
        scrollBtn.setTitle("scroll tmux", for: .normal)
        scrollBtn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        scrollBtn.setTitleColor(.black, for: .normal)
        scrollBtn.backgroundColor = SoyehtTheme.uiAccentGreen
        scrollBtn.layer.cornerRadius = 6
        scrollBtn.addTarget(self, action: #selector(scrollTmuxTapped), for: .touchUpInside)
        scrollBtn.translatesAutoresizingMaskIntoConstraints = false
        scrollBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        scrollBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        scrollBtn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.addArrangedSubview(scrollBtn)
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        btn.setTitleColor(SoyehtTheme.uiTextPrimary, for: .normal)
        btn.backgroundColor = SoyehtTheme.uiBgPrimary
        btn.layer.cornerRadius = 5
        btn.addTarget(self, action: action, for: .touchDown)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return btn
    }

    private func makeArrowButton(icon: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        btn.setImage(UIImage(systemName: icon, withConfiguration: config)?.withTintColor(SoyehtTheme.uiTextPrimary, renderingMode: .alwaysOriginal), for: .normal)
        btn.backgroundColor = SoyehtTheme.uiBgPrimary
        btn.layer.cornerRadius = 5
        btn.addTarget(self, action: action, for: .touchDown)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchUpInside)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchUpOutside)
        btn.addTarget(self, action: #selector(cancelRepeat), for: .touchCancel)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 36).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return btn
    }

    private func clickAndSend(_ data: [UInt8]) {
        UIDevice.current.playInputClick()
        terminalView?.send(data)
    }

    @objc private func tabTapped() { clickAndSend([0x9]) }
    @objc private func escTapped() { clickAndSend([0x1b]) }

    @objc private func ctrlTapped() {
        UIDevice.current.playInputClick()
        controlModifier.toggle()
        controlButton?.backgroundColor = controlModifier ? tintColor : SoyehtTheme.uiBgPrimary
        if let accessory = terminalView?.inputAccessoryView as? TerminalAccessory {
            accessory.controlModifier = controlModifier
        }
    }

    @objc private func scrollTmuxTapped() {
        UIDevice.current.playInputClick()
        NotificationCenter.default.post(name: .soyehtScrollTmuxTapped, object: nil)
    }

    private func startRepeat(_ action: @escaping () -> Void) {
        action()
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !(repeatTask?.isCancelled ?? true) else { return }
            await MainActor.run {
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    action()
                }
            }
        }
    }

    private func sendArrow(_ appSeq: [UInt8], _ normalSeq: [UInt8]) {
        guard let tv = terminalView else { return }
        let seq = tv.getTerminal().applicationCursor ? appSeq : normalSeq
        tv.send(seq)
    }

    @objc private func upTapped() {
        startRepeat { [weak self] in self?.sendArrow(EscapeSequences.moveUpApp, EscapeSequences.moveUpNormal) }
    }
    @objc private func downTapped() {
        startRepeat { [weak self] in self?.sendArrow(EscapeSequences.moveDownApp, EscapeSequences.moveDownNormal) }
    }
    @objc private func leftTapped() {
        startRepeat { [weak self] in self?.sendArrow(EscapeSequences.moveLeftApp, EscapeSequences.moveLeftNormal) }
    }
    @objc private func rightTapped() {
        startRepeat { [weak self] in self?.sendArrow(EscapeSequences.moveRightApp, EscapeSequences.moveRightNormal) }
    }

    @objc private func cancelRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatTask?.cancel()
        repeatTask = nil
    }
}
