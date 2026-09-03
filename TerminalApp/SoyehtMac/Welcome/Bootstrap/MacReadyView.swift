import SwiftUI
import SoyehtCore

/// M6 — the end of setup. Two ways forward and no decision to research: open
/// the app, or wire up the agents first.
struct MacReadyView: View {
    let onConnectAgents: () -> Void
    let onOpen: () -> Void

    private let palette = NeoPalette.cloud

    var body: some View {
        WelcomeStepScaffold(
            step: 4,
            title: LocalizedStringResource(
                "bootstrap.ready.title",
                defaultValue: "\(Self.macName) is ready.",
                comment: "M6: title once setup is finished. %@ is the Mac's name."
            ),
            body: LocalizedStringResource(
                "bootstrap.ready.body",
                defaultValue: "Your agents run here. Open Soyeht and you will land in a terminal.",
                comment: "M6: what happens next."
            ),
            content: { EmptyView() },
            footer: {
                HStack(spacing: 16) {
                    Button(action: onConnectAgents) {
                        Text(LocalizedStringResource(
                            "bootstrap.ready.connectAgents",
                            defaultValue: "Connect agents",
                            comment: "M6: optional step that wires Soyeht into the AI agent CLIs."
                        ))
                    }
                    .buttonStyle(NeoLinkButtonStyle(palette: palette))
                    .accessibilityIdentifier("soyeht.welcome.m6.connectAgents")

                    Spacer()

                    Button(action: onOpen) {
                        Text(LocalizedStringResource(
                            "bootstrap.ready.open",
                            defaultValue: "Open Soyeht",
                            comment: "M6: primary button that closes setup and opens the app."
                        ))
                    }
                    .buttonStyle(NeoPillButtonStyle(.primary, palette: palette, fillsWidth: false))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("soyeht.welcome.m6.open")
                }
            }
        )
    }

    private static var macName: String {
        Host.current().localizedName ?? "This Mac"
    }
}
