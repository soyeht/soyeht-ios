import SwiftUI
import SoyehtCore

/// House creation progress scene.
/// Shows a spinning key animation while `POST /bootstrap/initialize` runs.
/// Uses `AnimationCatalog.keyForging` token (FR-101). Respects Reduce Motion (FR-082).
/// T049a wires real BootstrapInitializeClient when implemented.
struct HouseCreationProgressView: View {
    let houseName: String
    let onCreated: () -> Void

    @State private var keyRotation: Double = 0
    @State private var showKey = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                keyIcon

                VStack(spacing: 8) {
                    Text(LocalizedStringResource(
                        "bootstrap.houseCreation.title",
                        defaultValue: "Criando a identidade da casa…",
                        comment: "House creation progress title shown during key generation."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                    .foregroundColor(BrandColors.textPrimary)
                    .multilineTextAlignment(.center)

                    Text(LocalizedStringResource(
                        "bootstrap.houseCreation.subtitle",
                        defaultValue: "Isso vai levar só um momento.",
                        comment: "House creation subtitle. Reassures brevity."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(showKey ? 1 : 0)
        .task { await runCreation() }
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.houseCreation.a11y",
            defaultValue: "Estou criando a identidade da \(houseName).",
            comment: "House creation VoiceOver label with house name."
        )))
    }

    private var keyIcon: some View {
        Text("🔑")
            .font(.system(size: 56))
            .rotationEffect(.degrees(keyRotation))
            .accessibilityHidden(true)
    }

    private func runCreation() async {
        withAnimation(.easeIn(duration: 0.3)) { showKey = true }

        // FR-101: AnimationCatalog.keyForging token (2.7s normal, 0.3s reduce motion).
        // Reduce Motion: key appears statically; no spinning.
        if !reduceMotion {
            withAnimation(AnimationCatalog.keyForging(reduceMotion: false).repeatCount(1, autoreverses: false)) {
                keyRotation = 360
            }
        }

        let sleepMs = reduceMotion ? 300 : Int(AnimationCatalog.Duration.keyForgingTotal * 1_000)
        do {
            // T049a replaces this with BootstrapInitializeClient.initialize(houseName:) call
            try await Task.sleep(for: .milliseconds(sleepMs))
        } catch {
            return
        }

        onCreated()
    }
}
