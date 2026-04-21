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

    @State private var linkText: String = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            pasteField
            HStack(spacing: 8) {
                Button("Conectar", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if UIPasteboardLinkCandidate.fromPasteboard() != nil && linkText.isEmpty {
                    Button("Colar do clipboard", action: pasteFromClipboard)
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
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrandColors.surfaceDeep)
        .onAppear(perform: autoPasteIfAvailable)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Conectar a servidor existente")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text("Cole o link theyos:// que o Admin Panel gerou. Formato: theyos://connect?token=…&host=…")
                .font(.system(size: 12))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pasteField: some View {
        TextField("theyos://connect?token=…&host=…", text: $linkText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .disabled(isConnecting)
    }

    // MARK: - Actions

    private func autoPasteIfAvailable() {
        guard linkText.isEmpty, let candidate = UIPasteboardLinkCandidate.fromPasteboard() else { return }
        linkText = candidate
    }

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
            error = "Link inválido. Esperado formato theyos://connect?token=…&host=…"
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
