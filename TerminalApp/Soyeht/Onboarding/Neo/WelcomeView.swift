import SoyehtCore
import SwiftUI

/// I1 — the first screen of the phone.
///
/// It used to be a six-card carousel about agents, teams, voice, the store
/// and security by design, shown before the user had anything to be secure
/// about. What a first launch owes the person holding the phone is one
/// sentence about what this is and one button that starts it; the rest is
/// something they will discover by using it.
struct WelcomeView: View {
    let onGetStarted: () -> Void

    private let palette = NeoPalette.cloud

    var body: some View {
        OnboardingScaffold(palette: palette) {
            VStack(spacing: 20) {
                mark

                Text(LocalizedStringResource(
                    "onboarding.welcome.title",
                    defaultValue: "Your Mac, in your pocket.",
                    comment: "I1 title — the first line a new iPhone shows."
                ))
                .font(NeoFont.title)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)

                Text(LocalizedStringResource(
                    "onboarding.welcome.body",
                    defaultValue: "Soyeht runs your terminals and AI agents on your Mac. This iPhone opens them from anywhere.",
                    comment: "I1 body — one paragraph explaining what the app is."
                ))
                .font(NeoFont.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(action: onGetStarted) {
                Text(LocalizedStringResource(
                    "onboarding.welcome.cta",
                    defaultValue: "Get started",
                    comment: "I1 primary button."
                ))
            }
            .buttonStyle(NeoPillButtonStyle(.primary, palette: palette))
            .accessibilityIdentifier(AccessibilityID.Onboarding.welcomeGetStarted)
        }
    }

    /// The one piece of decoration on the screen: the app's own shape, raised
    /// off the canvas so the style introduces itself before the copy does.
    private var mark: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(palette.accent)
            .frame(width: 96, height: 96)
            .neoRaised(palette, radius: NeoRadius.card, elevation: .hero)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
    }
}
