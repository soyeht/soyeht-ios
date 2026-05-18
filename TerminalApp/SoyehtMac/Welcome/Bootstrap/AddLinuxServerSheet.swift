import SwiftUI
import SoyehtCore

/// MVP add-Linux-server flow surfaced from `HouseCardView`. The bigger
/// product story is "pair a remote theyOS host", but for now this sheet
/// is a developer-grade entry point: the user pastes the host URL and a
/// session token issued by the remote `soyeht-admin-host` service, and
/// we register it as the active `PairedServer` so subsequent terminal
/// panes route through `MacOSWebSocketTerminalView.configure(wsUrl:)`.
///
/// Why two fields instead of "scan QR / paste pair link":
/// - Mac has no camera.
/// - The iOS pair-link parser (~1.7k lines, UIKit-bound) doesn't port
///   directly; landing it on macOS is a separate, larger feature.
/// - For internal `devs`-style testing, the operator already has SSH to
///   the host and can `theyos token issue` (or read it from the admin
///   service config) and paste it here.
///
/// Once a richer pair-link/QR flow exists on Mac, this sheet can be
/// dropped or repurposed as the "advanced/manual" tab of that flow.
@MainActor
struct AddLinuxServerSheet: View {
    let onConnected: () -> Void
    let onCancel: () -> Void

    @State private var host: String = ""
    @State private var token: String = ""
    @State private var serverName: String = ""
    @State private var errorMessage: LocalizedStringResource?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringResource(
                "addLinuxServer.title",
                defaultValue: "Add Linux server",
                comment: "Title of the Add Linux server sheet."
            ))
            .font(MacTypography.Fonts.Display.heroTitle)
            .foregroundColor(BrandColors.textPrimary)

            Text(LocalizedStringResource(
                "addLinuxServer.body",
                defaultValue: "Paste the host URL and the session token issued by the remote theyOS server. The Mac will use this server for all new terminal sessions.",
                comment: "Body explaining the manual add flow."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textMuted)

            VStack(alignment: .leading, spacing: 12) {
                labeledField(
                    label: LocalizedStringResource(
                        "addLinuxServer.field.host",
                        defaultValue: "Host URL",
                        comment: "Label for host URL field."
                    ),
                    placeholder: "https://100.82.47.115:443",
                    text: $host,
                    secure: false
                )

                labeledField(
                    label: LocalizedStringResource(
                        "addLinuxServer.field.token",
                        defaultValue: "Session token",
                        comment: "Label for session token field."
                    ),
                    placeholder: "Paste token issued by theyOS server",
                    text: $token,
                    secure: true
                )

                labeledField(
                    label: LocalizedStringResource(
                        "addLinuxServer.field.name",
                        defaultValue: "Display name (optional)",
                        comment: "Label for optional display name field."
                    ),
                    placeholder: "devs",
                    text: $serverName,
                    secure: false
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(action: onCancel) {
                    Text(LocalizedStringResource(
                        "addLinuxServer.cancel",
                        defaultValue: "Cancel",
                        comment: "Cancel button."
                    ))
                }
                .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    HStack(spacing: 6) {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        }
                        Text(LocalizedStringResource(
                            "addLinuxServer.connect",
                            defaultValue: "Connect",
                            comment: "Primary CTA. Persists the server and makes it active."
                        ))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || !isValid)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func labeledField(
        label: LocalizedStringResource,
        placeholder: String,
        text: Binding<String>,
        secure: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(MacTypography.Fonts.welcomeProgressTitle)
                .foregroundColor(BrandColors.textMuted)
            if secure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func submit() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard URL(string: trimmedHost) != nil else {
            errorMessage = LocalizedStringResource(
                "addLinuxServer.error.invalidHost",
                defaultValue: "Host URL is invalid.",
                comment: "Error: host URL didn't parse."
            )
            return
        }

        isSubmitting = true
        errorMessage = nil

        let server = PairedServer(
            id: UUID().uuidString,
            host: trimmedHost,
            name: trimmedName.isEmpty ? trimmedHost : trimmedName,
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux"
        )

        let store = SessionStore.shared
        _ = store.addServer(server, token: trimmedToken)
        store.setActiveServer(id: server.id)

        isSubmitting = false
        onConnected()
    }
}
