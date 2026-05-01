import SwiftUI
import SoyehtCore

/// Install-on-this-Mac flow (US-02). Two steps:
///   1. Pick network mode (localhost vs Tailscale).
///   2. Run the installer; on success, auto-pair via bootstrap-token and
///      let the parent open the main window.
struct LocalInstallView: View {
    let onPaired: () -> Void
    let compact: Bool
    /// Reuse an existing theyOS install instead of running the full brew
    /// pipeline. Drives copy + hides the network-mode picker (the existing
    /// install's `~/.theyos/.env` already encodes that decision).
    let skipBrew: Bool

    init(onPaired: @escaping () -> Void, compact: Bool = false, skipBrew: Bool = false) {
        self.onPaired = onPaired
        self.compact = compact
        self.skipBrew = skipBrew
    }

    @StateObject private var installer = TheyOSInstaller()
    @State private var selectedMode: TheyOSInstallMode = .localhost
    @State private var hasStarted = false
    @State private var pairError: String?
    @State private var isPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if !hasStarted {
                // Reuse path: the existing install already chose its
                // network mode in `~/.theyos/.env`; re-asking would be
                // misleading. Just show the start button.
                if !skipBrew {
                    modePicker
                }
                startButton
            } else {
                progressPanel
            }

            // In compact mode the host (drawer ScrollView) controls scroll +
            // height, so we must NOT push intrinsic height to infinity here.
            if !compact {
                Spacer()
            }
        }
        .padding(compact ? 16 : 32)
        .frame(
            maxWidth: .infinity,
            maxHeight: compact ? nil : .infinity,
            alignment: .topLeading
        )
        .background(BrandColors.surfaceDeep)
        .onReceive(NotificationCenter.default.publisher(for: WelcomeWindowNotifications.willClose)) { _ in
            // Welcome window is closing — terminate any in-flight install
            // so the `brew` / `soyeht` subprocess isn't left orphaned.
            installer.cancel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerTitle)
                .font(MacTypography.Fonts.welcomeFlowTitle(compact: compact))
                .foregroundColor(.white)
            Text(headerDescription)
                .font(MacTypography.Fonts.welcomeFlowBody(compact: compact))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerTitle: LocalizedStringResource {
        skipBrew
            ? LocalizedStringResource(
                "welcome.localInstall.header.title.reuse",
                defaultValue: "Connect to your theyOS",
                comment: "Header title shown when the Welcome flow detected an existing theyOS install and the user chose Reuse — we're not installing, just starting + auto-pairing."
            )
            : LocalizedStringResource(
                "welcome.localInstall.header.title",
                comment: "Header title for the fresh install path."
            )
    }

    private var headerDescription: LocalizedStringResource {
        skipBrew
            ? LocalizedStringResource(
                "welcome.localInstall.header.description.reuse",
                defaultValue: "We detected an existing install. The app will start the server and pair this Mac.",
                comment: "Header copy explaining the Reuse path — no brew install will run; we just start the existing daemon and pair."
            )
            : LocalizedStringResource(
                "welcome.localInstall.header.description",
                comment: "Header copy for the fresh install path."
            )
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("welcome.localInstall.modePicker.label")
                .font(MacTypography.Fonts.welcomeSectionLabel)
                .foregroundColor(.white)
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TheyOSInstallMode.allCases) { mode in
                        ModeCard(
                            mode: mode,
                            isSelected: mode == selectedMode,
                            tailscaleAvailable: TheyOSEnvironment.isTailscaleInstalled(),
                            compact: compact,
                            action: { selectedMode = mode }
                        )
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(TheyOSInstallMode.allCases) { mode in
                        ModeCard(
                            mode: mode,
                            isSelected: mode == selectedMode,
                            tailscaleAvailable: TheyOSEnvironment.isTailscaleInstalled(),
                            compact: compact,
                            action: { selectedMode = mode }
                        )
                    }
                }
            }
        }
    }

    private var startButton: some View {
        let stack = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return stack {
            Button(startButtonLabel, action: beginInstall)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            if !skipBrew && selectedMode == .tailscale && !TheyOSEnvironment.isTailscaleInstalled() {
                Text("welcome.localInstall.warning.tailscaleNotFound")
                    .font(MacTypography.Fonts.welcomeWarning)
                    .foregroundColor(BrandColors.accentAmber)
            }
        }
        .padding(.top, 8)
    }

    private var startButtonLabel: LocalizedStringResource {
        skipBrew
            ? LocalizedStringResource(
                "welcome.localInstall.button.reuse",
                defaultValue: "Connect",
                comment: "Primary button on the Reuse path — starts soyeht (if not already running) and auto-pairs."
            )
            : LocalizedStringResource(
                "welcome.localInstall.button.install",
                comment: "Primary button on the fresh install path."
            )
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            progressBar

            HStack(alignment: .top, spacing: 8) {
                phaseDot
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(installer.phase.displayTitle)
                        .font(MacTypography.Fonts.welcomeProgressTitle)
                        .foregroundColor(.white)
                    if let subPhase = installer.subPhase {
                        Text(subPhase)
                            .font(MacTypography.Fonts.welcomeProgressBody)
                            .foregroundColor(BrandColors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                phaseTimer
                if isPairing {
                    Text("welcome.localInstall.status.pairing")
                        .font(MacTypography.Fonts.welcomeProgressBody)
                        .foregroundColor(BrandColors.textMuted)
                }
            }

            if let pairError {
                Text(pairError)
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("welcome.localInstall.button.retry", action: retry)
                    .buttonStyle(.bordered)
            }

            logTail
        }
    }

    /// During `.startingServer` the subprocess covers a ~17 GB IPSW
    /// download + VM boot and emits sparse log lines, so a value-based
    /// bar would freeze near 85% for 20–30 min and read as wedged. Switch
    /// to an indeterminate animation here so the user sees motion.
    @ViewBuilder
    private var progressBar: some View {
        if case .startingServer = installer.phase {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(BrandColors.accentGreen)
        } else {
            ProgressView(value: installer.phase.fractionComplete)
                .progressViewStyle(.linear)
                .tint(BrandColors.accentGreen)
        }
    }

    /// Continuously-updating elapsed-time counter for the current phase.
    /// Only meaningful while we're working — hidden once the install has
    /// terminated (success or failure) so the final timestamp doesn't keep
    /// ticking forever.
    @ViewBuilder
    private var phaseTimer: some View {
        if !installer.phase.isTerminal {
            Text(installer.phaseStartedAt, style: .timer)
                .font(MacTypography.Fonts.welcomeTimer)
                .foregroundColor(BrandColors.textMuted)
                .monospacedDigit()
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
                        .font(MacTypography.Fonts.welcomeLog)
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
            try await installer.install(mode: selectedMode, skipBrew: skipBrew)
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
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mode.displayTitle)
                    .font(MacTypography.Fonts.welcomeModeTitle)
                    .foregroundColor(.white)
                Text(mode.displayDescription)
                    .font(MacTypography.Fonts.welcomeModeBody)
                    .foregroundColor(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if mode == .tailscale {
                    Text(tailscaleAvailable ? LocalizedStringResource("welcome.localInstall.modeCard.tailscale.detected", comment: "Mode card badge — Tailscale is installed and reachable.") : LocalizedStringResource("welcome.localInstall.modeCard.tailscale.notDetected", comment: "Mode card badge — Tailscale app not installed on this Mac."))
                        .font(MacTypography.Fonts.welcomeModeBadge)
                        .foregroundColor(tailscaleAvailable ? BrandColors.accentGreen : BrandColors.accentAmber)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 96 : 120, alignment: .topLeading)
            .padding(compact ? 12 : 16)
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
