import SwiftUI
import SoyehtCore

/// Complete-uninstall flow (US-09 — "remover completamente do meu computador").
/// Two phases mirroring the install flow:
///   1. Confirmation gate — explains what will be deleted (~100GB) and which
///      paired servers will be disconnected.
///   2. Progress panel — runs `TheyOSUninstaller` with live phase + log tail.
struct UninstallTheyOSView: View {
    let onCompleted: () -> Void
    let compact: Bool

    init(onCompleted: @escaping () -> Void, compact: Bool = false) {
        self.onCompleted = onCompleted
        self.compact = compact
    }

    @StateObject private var uninstaller = TheyOSUninstaller()
    @State private var hasStarted = false
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if !hasStarted {
                confirmationPanel
            } else {
                progressPanel
            }

            // In compact mode the host (drawer ScrollView) controls scroll +
            // height. Pushing intrinsic height to .infinity here would leak
            // back out to the AppKit window via NSHostingController.
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("welcome.uninstall.header.title")
                .font(.system(size: compact ? 16 : 20, weight: .semibold))
                .foregroundColor(.white)
            Text("welcome.uninstall.header.description")
                .font(.system(size: compact ? 11 : 12))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Confirmation

    private var confirmationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            warningCard
            startButton
        }
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("welcome.uninstall.warning.title")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(BrandColors.accentAmber)
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("welcome.uninstall.warning.bullet.vms")
                bullet("welcome.uninstall.warning.bullet.data")
                bullet("welcome.uninstall.warning.bullet.servers")
                bullet("welcome.uninstall.warning.bullet.brew")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(BrandColors.accentAmber.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(BrandColors.textMuted)
            Text(key)
                .font(.system(size: 11))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startButton: some View {
        Button("welcome.uninstall.button.confirm", action: beginUninstall)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.accentAmber)
            .padding(.top, 4)
    }

    // MARK: - Progress

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: uninstaller.phase.fractionComplete)
                .progressViewStyle(.linear)
                .tint(BrandColors.accentAmber)

            HStack(spacing: 8) {
                phaseDot
                Text(uninstaller.phase.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.system(size: 12))
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("welcome.uninstall.button.retry", action: retry)
                    .buttonStyle(.bordered)
            }

            if let hint = uninstaller.residualHint {
                Text(hint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if case .done = uninstaller.phase {
                Button("welcome.uninstall.button.dismiss", action: onCompleted)
                    .buttonStyle(.borderedProminent)
            }

            logTail
        }
    }

    private var phaseDot: some View {
        let color: Color = {
            if case .failed = uninstaller.phase { return BrandColors.accentAmber }
            if case .done = uninstaller.phase { return BrandColors.accentGreen }
            return BrandColors.accentAmber.opacity(0.7)
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var logTail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(uninstaller.log.suffix(20).enumerated()), id: \.offset) { _, line in
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

    private func beginUninstall() {
        hasStarted = true
        failureMessage = nil
        Task { await runFullFlow() }
    }

    private func retry() {
        failureMessage = nil
        Task { await runFullFlow() }
    }

    private func runFullFlow() async {
        do {
            try await uninstaller.uninstall()
        } catch {
            failureMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
