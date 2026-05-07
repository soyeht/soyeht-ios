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
                    .font(MacTypography.Fonts.welcomeProgressBody)
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
                .font(MacTypography.Fonts.welcomeFlowTitle(compact: compact))
                .foregroundColor(BrandColors.textPrimary)
            Text("welcome.remoteConnect.header.description")
                .font(MacTypography.Fonts.welcomeFlowBody(compact: compact))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pasteField: some View {
        TextField("welcome.remoteConnect.textField.placeholder", text: $linkText)
            .textFieldStyle(.roundedBorder)
            .font(MacTypography.Fonts.welcomeBodyMono)
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
        // Capture the callback up front so the Task does not implicitly
        // send `self` (a SwiftUI View struct) across the actor boundary —
        // under -strict-concurrency=complete that pattern is rejected as
        // "Sending 'self' risks data race". Mutations of `error` and
        // `isConnecting` are routed back through `MainActor.run`.
        let onPairedCallback = onPaired
        Task {
            do {
                switch scan {
                case .connect(let token, let host), .pair(let token, let host):
                    _ = try await SoyehtAPIClient.shared.pairServer(token: token, host: host)
                case .invite(let token, let host):
                    _ = try await SoyehtAPIClient.shared.redeemInvite(token: token, host: host)
                case .householdPairDevice, .householdPairMachine:
                    throw SoyehtAPIClient.APIError.invalidURL
                }
                await MainActor.run {
                    isConnecting = false
                    onPairedCallback()
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    isConnecting = false
                    self.error = message
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
