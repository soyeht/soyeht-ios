import SwiftUI
import SoyehtCore

/// Welcome mode: local engine state exists — poll until ready or awaiting-pair, then hand off.
struct RecoverView: View {
    let onRecovered: () -> Void

    @State private var awaitingPair = false
    @State private var errorKey: LocalizedStringResource?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let errorKey {
                Text(LocalizedStringResource(
                    "recover.error.title",
                    defaultValue: "Não foi possível reconectar.",
                    comment: "Recover: engine regressed to unexpected state."
                ))
                .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)

                Text(errorKey)
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
        let client = BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL)
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
                    errorKey = LocalizedStringResource(
                        "recover.error.regressed",
                        defaultValue: "Sua casa precisou recomeçar. Abra o Soyeht de novo pra continuarmos.",
                        comment: "Shown when household state regressed during recovery polling."
                    )
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
