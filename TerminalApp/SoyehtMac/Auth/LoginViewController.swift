//
//  LoginViewController.swift
//  Soyeht
//
//  Single-field login: accepts the full theyos:// connection link
//  (as shown / copied from the Soyeht web dashboard or QR code).
//  Format: theyos://connect?token=X&host=Y
//

import Cocoa
import SoyehtCore

class LoginViewController: NSViewController {

    private let linkField = NSTextField()
    private let connectButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private var isConnecting = false

    var onSuccess: (() -> Void)?

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 380, height: 160))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: String(localized: "auth.login.title", comment: "Title above the login form — 'Connect to Soyeht Server'. 'Soyeht' is the product name."))
        title.font = MacTypography.NSFonts.authTitle
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let hint = NSTextField(labelWithString: String(localized: "auth.login.hint", comment: "Hint under the login title prompting the user to paste a connection link from the dashboard."))
        hint.font = MacTypography.NSFonts.authBody
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        linkField.placeholderString = String(localized: "auth.login.placeholder", comment: "Placeholder showing the expected link format. Keep theyos:// intact.")
        linkField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(linkField)

        errorLabel.textColor = .systemRed
        errorLabel.font = MacTypography.NSFonts.authBody
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)

        connectButton.title = String(localized: "auth.login.button.connect", comment: "Primary action in the login form.")
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(connectButton)

        let cancelButton = NSButton(title: String(localized: "common.button.cancel", comment: "Generic Cancel."), target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            linkField.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            linkField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            linkField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            errorLabel.topAnchor.constraint(equalTo: linkField.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),

            connectButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            connectButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Pre-fill from URL scheme

    /// Called when the app opens a theyos:// URL — the full URL is pre-filled.
    func prefill(host: String, token: String) {
        let url = "theyos://connect?token=\(token)&host=\(host)"
        linkField.stringValue = url
    }

    // MARK: - Actions

    @objc private func connectTapped() {
        let raw = linkField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            errorLabel.stringValue = String(localized: "auth.login.error.empty", comment: "Error shown when the user tapped Connect with an empty input.")
            return
        }

        guard let (token, host) = parseLink(raw) else {
            errorLabel.stringValue = String(localized: "auth.login.error.invalid", comment: "Error shown when the pasted text isn't a valid theyos:// link.")
            return
        }

        guard !isConnecting else { return }
        isConnecting = true
        connectButton.isEnabled = false
        errorLabel.stringValue = String(localized: "auth.login.status.connecting", comment: "Status shown while the pair-server RPC is in flight.")

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await SoyehtAPIClient.shared.pairServer(token: token, host: host)
                await MainActor.run {
                    self.isConnecting = false
                    self.dismiss(nil)
                    self.onSuccess?()
                }
            } catch {
                await MainActor.run {
                    self.isConnecting = false
                    self.connectButton.isEnabled = true
                    self.errorLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func cancelTapped() {
        dismiss(nil)
    }

    // MARK: - Parsing

    /// Accepts:
    ///   theyos://connect?token=X&host=Y   (full link from dashboard/QR code)
    ///   theyos://pair?token=X&host=Y
    ///   theyos://invite?token=X&host=Y
    private func parseLink(_ raw: String) -> (token: String, host: String)? {
        guard let url = URL(string: raw),
              let result = QRScanResult.from(url: url) else { return nil }
        switch result {
        case .connect(let token, let host),
             .pair(let token, let host),
             .invite(let token, let host):
            return (token, host)
        }
    }
}
