import SwiftUI
import SoyehtCore
import AppKit

/// Paste-a-link flow for users that already have a theyOS server running
/// somewhere else (US-04). The same contract as the legacy
/// `LoginViewController` — accept `theyos://connect`, `theyos://pair`,
/// or `theyos://invite` — exposed as a SwiftUI form inside the welcome
/// window so the two branches share one look.
struct RemoteConnectView: View {
    let onPaired: () -> Void
    let compact: Bool

    init(onPaired: @escaping () -> Void, compact: Bool = false) {
        self.onPaired = onPaired
        self.compact = compact
    }

    @State private var linkText: String = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            pasteField
            HStack(spacing: 8) {
                Button("welcome.remoteConnect.button.connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if UIPasteboardLinkCandidate.fromPasteboard() != nil && linkText.isEmpty {
                    Button("welcome.remoteConnect.button.pasteClipboard", action: pasteFromClipboard)
                        .buttonStyle(.bordered)
                }
                if isConnecting {
                    ProgressView().scaleEffect(0.6)
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // In compact mode the host (drawer ScrollView) owns the scroll +
            // height. Letting this view bloat to maxHeight: .infinity here
            // can leak intrinsic size to the AppKit window.
            if !compact {
                Spacer()
            }
        }
        .padding(compact ? 16 : 32)
        .frame(
            maxWidth: .infinity,
            maxHeight: compact ? nil : .infinity,
            alignment: .topLeading
        )
        .background(BrandColors.surfaceDeep)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("welcome.remoteConnect.header.title")
                .font(.system(size: compact ? 16 : 20, weight: .semibold))
                .foregroundColor(.white)
            Text("welcome.remoteConnect.header.description")
                .font(.system(size: compact ? 11 : 12))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pasteField: some View {
        TextField("welcome.remoteConnect.textField.placeholder", text: $linkText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .disabled(isConnecting)
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        if let candidate = UIPasteboardLinkCandidate.fromPasteboard() {
            linkText = candidate
        }
    }

    private func connect() {
        error = nil
        let raw = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let url = URL(string: raw), let scan = QRScanResult.from(url: url) else {
            error = String(localized: "welcome.remoteConnect.error.invalidLink", comment: "Shown when the pasted text doesn't parse as a theyos:// deep link.")
            return
        }
        isConnecting = true
        Task {
            defer { Task { @MainActor in isConnecting = false } }
            do {
                switch scan {
                case .connect(let token, let host), .pair(let token, let host):
                    _ = try await SoyehtAPIClient.shared.pairServer(token: token, host: host)
                case .invite(let token, let host):
                    _ = try await SoyehtAPIClient.shared.redeemInvite(token: token, host: host)
                }
                await MainActor.run { onPaired() }
            } catch {
                await MainActor.run {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

/// Helper that peeks at the general `NSPasteboard` for anything that looks
/// like a `theyos://` deep link. Used to populate the paste field on appear
/// so the user doesn't have to cmd-V manually after copying from the admin
/// panel's "Copy Link" button.
private enum UIPasteboardLinkCandidate {
    static func fromPasteboard() -> String? {
        guard let content = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("theyos://") else { return nil }
        return trimmed
    }
}
