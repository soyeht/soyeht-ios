import SwiftUI
import SoyehtCore

/// M1 — the first thing a new owner sees. One sentence about what Soyeht is,
/// one button. Nothing to decide, nothing to read twice.
struct BootstrapWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        WelcomeStepScaffold(
            step: 1,
            title: LocalizedStringResource(
                "bootstrap.welcome.title",
                defaultValue: "Welcome to Soyeht.",
                comment: "M1: welcome headline, first launch."
            ),
            body: LocalizedStringResource(
                "bootstrap.welcome.body",
                defaultValue: "Soyeht runs your AI agents on this Mac and lets you reach them from your iPhone. Setting up takes about a minute.",
                comment: "M1: one paragraph explaining what the app is before anything is installed."
            ),
            content: { EmptyView() },
            footer: {
                HStack {
                    Spacer()
                    Button(action: onContinue) {
                        Text(LocalizedStringResource(
                            "bootstrap.welcome.cta",
                            defaultValue: "Set up this Mac",
                            comment: "M1: primary button that starts the install."
                        ))
                    }
                    .buttonStyle(NeoPillButtonStyle(.primary, palette: .cloud, fillsWidth: false))
                    .accessibilityIdentifier(WelcomeAccessibilityID.m1SetUp)
                    .keyboardShortcut(.defaultAction)
                }
            }
        )
    }
}
