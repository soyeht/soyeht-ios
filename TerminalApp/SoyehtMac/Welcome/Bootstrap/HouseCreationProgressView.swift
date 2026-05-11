import SwiftUI
import SoyehtCore

/// House creation progress scene.
/// Shows a spinning key animation while `POST /bootstrap/initialize` runs.
/// Uses `AnimationCatalog.keyForging` token (FR-101). Respects Reduce Motion (FR-082).
struct HouseCreationProgressView: View {
    let houseName: String
    let onCreated: () -> Void

    @State private var keyRotation: Double = 0
    @State private var showKey = false
    @State private var errorMessage: String?
    @State private var creationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if let message = errorMessage {
                VStack(spacing: 16) {
                    Text(LocalizedStringResource(
                        "bootstrap.houseCreation.error.title",
                        defaultValue: "Não consegui criar sua casa.",
                        comment: "Title shown when /bootstrap/initialize fails."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                    .foregroundColor(BrandColors.textPrimary)
                    .multilineTextAlignment(.center)

                    Text(verbatim: message)
                        .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                        .foregroundColor(BrandColors.textMuted)
                        .multilineTextAlignment(.center)

                    Button(action: {
                        errorMessage = nil
                        keyRotation = 0
                        creationTask?.cancel()
                        creationTask = Task { await runCreation() }
                    }) {
                        Text(LocalizedStringResource(
                            "bootstrap.houseCreation.error.retry",
                            defaultValue: "Tentar de novo",
                            comment: "Retry button after house creation failure."
                        ))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: 400)
            } else {
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
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(showKey ? 1 : 0)
        .onAppear {
            creationTask = Task { await runCreation() }
        }
        .onDisappear {
            creationTask?.cancel()
        }
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

        let scheme = SoyehtAPIClient.isLocalHost(TheyOSEnvironment.adminHost) ? "http" : "https"
        guard let baseURL = URL(string: "\(scheme)://\(TheyOSEnvironment.adminHost)") else { return }
        let client = BootstrapInitializeClient(baseURL: baseURL)
        let animMs = reduceMotion ? 300 : Int(AnimationCatalog.Duration.keyForgingTotal * 1_000)
        let start = Date()
        do {
            _ = try await client.initialize(name: houseName, claimToken: nil)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let elapsed = Int(-start.timeIntervalSinceNow * 1_000)
        let remaining = animMs - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .milliseconds(remaining))
        }
        onCreated()
    }
}
