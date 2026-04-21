import SwiftUI
import SoyehtCore

/// Install-on-this-Mac flow (US-02). Two steps:
///   1. Pick network mode (localhost vs Tailscale).
///   2. Run the installer; on success, auto-pair via bootstrap-token and
///      let the parent open the main window.
struct LocalInstallView: View {
    let onPaired: () -> Void

    @StateObject private var installer = TheyOSInstaller()
    @State private var selectedMode: TheyOSInstallMode = .localhost
    @State private var hasStarted = false
    @State private var pairError: String?
    @State private var isPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if !hasStarted {
                modePicker
                startButton
            } else {
                progressPanel
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrandColors.surfaceDeep)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instalar no meu Mac")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text("O app roda brew install theyos + soyeht start em background. Você não precisa abrir o terminal.")
                .font(.system(size: 12))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quem vai usar?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            HStack(alignment: .top, spacing: 12) {
                ForEach(TheyOSInstallMode.allCases) { mode in
                    ModeCard(
                        mode: mode,
                        isSelected: mode == selectedMode,
                        tailscaleAvailable: TheyOSEnvironment.isTailscaleInstalled(),
                        action: { selectedMode = mode }
                    )
                }
            }
        }
    }

    private var startButton: some View {
        HStack {
            Button("Instalar", action: beginInstall)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            if selectedMode == .tailscale && !TheyOSEnvironment.isTailscaleInstalled() {
                Text("Tailscale não detectado. Instale em tailscale.com/download.")
                    .font(.system(size: 11))
                    .foregroundColor(BrandColors.accentAmber)
            }
        }
        .padding(.top, 8)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: installer.phase.fractionComplete)
                .progressViewStyle(.linear)
                .tint(BrandColors.accentGreen)

            HStack(spacing: 8) {
                phaseDot
                Text(installer.phase.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                if isPairing {
                    Text("Pareando…")
                        .font(.system(size: 12))
                        .foregroundColor(BrandColors.textMuted)
                }
            }

            if let pairError {
                Text(pairError)
                    .font(.system(size: 12))
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Tentar novamente", action: retry)
                    .buttonStyle(.bordered)
            }

            logTail
        }
    }

    private var phaseDot: some View {
        let color: Color = {
            if case .failed = installer.phase { return BrandColors.accentAmber }
            if case .done = installer.phase { return BrandColors.accentGreen }
            return BrandColors.accentGreen.opacity(0.6)
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var logTail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(installer.log.suffix(20).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(BrandColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 160)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func beginInstall() {
        hasStarted = true
        pairError = nil
        Task { await runFullFlow() }
    }

    private func retry() {
        pairError = nil
        Task { await runFullFlow() }
    }

    private func runFullFlow() async {
        do {
            try await installer.install(mode: selectedMode)
            await attemptAutoPair()
        } catch {
            // installer.phase is already `.failed(...)`; surface the detailed
            // message here for the retry CTA.
            pairError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func attemptAutoPair() async {
        isPairing = true
        defer { isPairing = false }
        do {
            _ = try await TheyOSAutoPairService().autoPair()
            onPaired()
        } catch {
            pairError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Single card inside the network-mode picker. The "disabled" state is soft
/// — the user can still click a Tailscale card without Tailscale installed,
/// but the start button surfaces the requirement.
private struct ModeCard: View {
    let mode: TheyOSInstallMode
    let isSelected: Bool
    let tailscaleAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mode.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(mode.displayDescription)
                    .font(.system(size: 11))
                    .foregroundColor(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if mode == .tailscale {
                    Text(tailscaleAvailable ? "Tailscale detectado" : "Tailscale não detectado")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(tailscaleAvailable ? BrandColors.accentGreen : BrandColors.accentAmber)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(16)
            .background(isSelected ? BrandColors.accentGreen.opacity(0.12) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? BrandColors.accentGreen : Color.white.opacity(0.1), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
