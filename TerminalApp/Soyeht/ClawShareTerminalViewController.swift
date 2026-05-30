import UIKit
import SoyehtCore
import os

/// Hosts a `ClawShareTerminalView` and enforces the Apple-grade gate at the
/// screen level: the terminal is only revealed once the session reaches
/// `.interactiveReady`; if it ends (clean exit, target close, transport drop,
/// or revocation) the terminal is replaced by a recoverable, human state —
/// no technical strings, no generic "try again", no zombie session.
///
/// The client is injected already credential-loaded + session-started (the
/// caller signs the proof-of-possession token via the Secure-Enclave guest
/// identity and stages the endpoint). This VC owns only presentation,
/// gating, recovery, and teardown.
public final class ClawShareTerminalViewController: UIViewController {
    private static let logger = Logger(subsystem: "com.soyeht.mobile.clawshare", category: "terminal-vc")

    private let client: any ClawShareDataPlaneClient
    private let clawDisplayName: String
    /// Called when the user closes, or when the session ends and the user
    /// dismisses the recoverable state — the host removes any "open" entry.
    public var onClosed: (() -> Void)?

    private lazy var terminalView = ClawShareTerminalView(frame: .zero)
    private let connectingLabel = UILabel()
    private let recoveryView = UIView()
    private let recoveryLabel = UILabel()
    private let recoveryButton = UIButton(type: .system)

    public init(client: any ClawShareDataPlaneClient, clawDisplayName: String) {
        self.client = client
        self.clawDisplayName = clawDisplayName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = clawDisplayName

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeTapped)
        )

        setupTerminal()
        setupConnecting()
        setupRecovery()

        showConnecting()
        terminalView.onInteractiveReady = { [weak self] in self?.showTerminal() }
        terminalView.onSessionEnded = { [weak self] reason in self?.showRecovery(reason: reason) }
        terminalView.attach(client: client)
    }

    // MARK: - Layout

    private func setupTerminal() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.isHidden = true
        view.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func setupConnecting() {
        connectingLabel.translatesAutoresizingMaskIntoConstraints = false
        connectingLabel.textAlignment = .center
        connectingLabel.textColor = .secondaryLabel
        connectingLabel.text = String(
            localized: "clawShare.terminal.connecting",
            defaultValue: "Connecting to \(clawDisplayName)…",
            comment: "Shown while the claw-share interactive session is coming up."
        )
        view.addSubview(connectingLabel)
        NSLayoutConstraint.activate([
            connectingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectingLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            connectingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            connectingLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func setupRecovery() {
        recoveryView.translatesAutoresizingMaskIntoConstraints = false
        recoveryView.isHidden = true
        view.addSubview(recoveryView)

        recoveryLabel.translatesAutoresizingMaskIntoConstraints = false
        recoveryLabel.textAlignment = .center
        recoveryLabel.numberOfLines = 0
        recoveryLabel.textColor = .label

        recoveryButton.translatesAutoresizingMaskIntoConstraints = false
        recoveryButton.setTitle(
            String(localized: "clawShare.terminal.done", defaultValue: "Done", comment: "Dismiss the ended claw-share session."),
            for: .normal
        )
        recoveryButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        recoveryView.addSubview(recoveryLabel)
        recoveryView.addSubview(recoveryButton)
        NSLayoutConstraint.activate([
            recoveryView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            recoveryView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            recoveryView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            recoveryLabel.topAnchor.constraint(equalTo: recoveryView.topAnchor),
            recoveryLabel.leadingAnchor.constraint(equalTo: recoveryView.leadingAnchor),
            recoveryLabel.trailingAnchor.constraint(equalTo: recoveryView.trailingAnchor),
            recoveryButton.topAnchor.constraint(equalTo: recoveryLabel.bottomAnchor, constant: 16),
            recoveryButton.centerXAnchor.constraint(equalTo: recoveryView.centerXAnchor),
            recoveryButton.bottomAnchor.constraint(equalTo: recoveryView.bottomAnchor),
        ])
    }

    // MARK: - State

    private func showConnecting() {
        connectingLabel.isHidden = false
        terminalView.isHidden = true
        recoveryView.isHidden = true
    }

    private func showTerminal() {
        connectingLabel.isHidden = true
        recoveryView.isHidden = true
        terminalView.isHidden = false
        _ = terminalView.becomeFirstResponder()
    }

    /// Map a stable end reason to human, actionable copy — never a raw code,
    /// never a generic "try again". The session is already torn down, so the
    /// only action is to close (and the user re-opens from the share entry).
    private func showRecovery(reason: String) {
        Self.logger.info("terminal_recovery reason=\(reason, privacy: .public)")
        connectingLabel.isHidden = true
        terminalView.isHidden = true
        recoveryView.isHidden = false
        recoveryLabel.text = Self.recoveryCopy(reason: reason, claw: clawDisplayName)
    }

    private static func recoveryCopy(reason: String, claw: String) -> String {
        if reason.hasPrefix("transport") {
            return String(
                localized: "clawShare.terminal.ended.connection",
                defaultValue: "The connection to \(claw) dropped. Open it again when you’re ready.",
                comment: "Recoverable: the claw-share connection dropped."
            )
        }
        // session-ended, target exit, revocation, or open-gate failure.
        return String(
            localized: "clawShare.terminal.ended.closed",
            defaultValue: "The session on \(claw) closed. You can open it again from the share.",
            comment: "Recoverable: the claw-share session ended."
        )
    }

    @objc private func closeTapped() {
        terminalView.close()
        let done = onClosed
        dismiss(animated: true) { done?() }
    }
}
