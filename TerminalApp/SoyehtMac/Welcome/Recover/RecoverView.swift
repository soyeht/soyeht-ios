import SwiftUI
import SoyehtCore

/// Welcome mode: local engine state exists — poll until ready or awaiting-pair, then hand off.
struct RecoverView: View {
    let onRecovered: () -> Void

    @State private var awaitingPair = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let message = errorMessage {
                Text(LocalizedStringResource(
                    "recover.error.title",
                    defaultValue: "Não foi possível reconectar.",
                    comment: "Recover: engine regressed to unexpected state."
                ))
                .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)

                Text(verbatim: message)
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                    .tint(BrandColors.accentGreen)

                if awaitingPair {
                    Text(LocalizedStringResource(
                        "recover.awaitingPair",
                        defaultValue: "Sua casa está pronta.\nAbra o Soyeht no seu iPhone.",
                        comment: "Recover: house named, engine waiting for iPhone to pair."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                } else {
                    Text(LocalizedStringResource(
                        "recover.reconnecting",
                        defaultValue: "Reconectando à sua casa…",
                        comment: "Recover: reconnecting to engine after app relaunch."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceDeep)
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .task { await pollForReady() }
    }

    private func pollForReady() async {
        let scheme = SoyehtAPIClient.isLocalHost(TheyOSEnvironment.adminHost) ? "http" : "https"
        guard let baseURL = URL(string: "\(scheme)://\(TheyOSEnvironment.adminHost)") else { return }
        let client = BootstrapStatusClient(baseURL: baseURL)
        while !Task.isCancelled {
            if let status = try? await client.fetch() {
                switch status.state {
                case .ready:
                    onRecovered()
                    return
                case .namedAwaitingPair:
                    awaitingPair = true
                case .recovering:
                    break  // engine mid-recovery — keep waiting
                case .uninitialized, .readyForNaming:
                    // Engine regressed to pre-creation state; cannot recover without reinstall
                    errorMessage = "Engine regrediu para estado inicial. Reinicie o app."
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
