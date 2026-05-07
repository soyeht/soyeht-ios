import SwiftUI
import UIKit
import SoyehtCore

struct JoinRequestConfirmationHaptics {
    var confirmTapped: () -> Void
    var biometricSucceeded: () -> Void

    static let live = JoinRequestConfirmationHaptics(
        confirmTapped: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        },
        biometricSucceeded: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    )

    static let none = JoinRequestConfirmationHaptics(
        confirmTapped: {},
        biometricSucceeded: {}
    )
}

struct JoinRequestConfirmationView: View {
    @ObservedObject var viewModel: JoinRequestConfirmationViewModel

    let householdName: String
    var memberAddedHighlightToken: Int = 0
    var haptics: JoinRequestConfirmationHaptics = .live
    /// Called synchronously when the operator taps Confirm — *before*
    /// the unstructured `Task { await viewModel.confirm() }` is created.
    /// Hosts wire this to `HouseholdMachineJoinRuntime.beginConfirming`
    /// so the in-flight snapshot is published before the next main-actor
    /// re-render can rebuild the card host out from under the VM. See
    /// `confirmingRequest` doc on the runtime for the full race timeline.
    var onConfirmTap: () -> Void = {}
    var onSucceeded: () -> Void = {}
    var onDismissed: () -> Void = {}

    @State private var showSuccessCheckmark = false
    @State private var showMemberHighlight = false
    @State private var didReportSuccess = false
    @State private var didDismiss = false

    private let fingerprintColumns = [
        GridItem(.flexible(minimum: 112), spacing: 8),
        GridItem(.flexible(minimum: 112), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            machineSummary
            fingerprintSection
            messageSection
            actionRow
        }
        .padding(18)
        .frame(maxWidth: 420, alignment: .leading)
        .background(SoyehtTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(cardBorder)
        .accessibilityIdentifier(AccessibilityID.Household.joinRequestCard)
        .task { await runCountdown() }
        .onChange(of: viewModel.state) { newState in
            handleStateChange(newState)
        }
        .onChange(of: memberAddedHighlightToken) { _ in
            triggerMemberHighlight()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(Typography.monoBodyLargeBold)
                .foregroundColor(SoyehtTheme.accentGreen)
                .frame(width: 34, height: 34)
                .background(SoyehtTheme.accentGreenDim)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(Typography.monoSection)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(timeRemainingText)
                    .font(Typography.monoSmall)
                    .foregroundColor(viewModel.secondsRemaining > 30 ? SoyehtTheme.textComment : SoyehtTheme.accentAmberStrong)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)
        }
    }

    private var machineSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow(
                icon: "desktopcomputer",
                label: localized("household.machineJoin.card.hostnameLabel"),
                value: viewModel.displayHostname
            )
            infoRow(
                icon: "cpu",
                label: localized("household.machineJoin.card.platformLabel"),
                value: viewModel.displayPlatform
            )
        }
    }

    private var fingerprintSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "seal")
                    .font(Typography.monoSmallBold)
                    .foregroundColor(SoyehtTheme.accentInfo)
                Text(localized("household.machineJoin.card.fingerprintLabel"))
                    .font(Typography.monoSectionLabel)
                    .foregroundColor(SoyehtTheme.textComment)
            }

            ZStack {
                if showSuccessCheckmark {
                    successCheckmark
                        .transition(.scale(scale: 0.84).combined(with: .opacity))
                } else {
                    fingerprintGrid
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118)

            Text(localized("household.machineJoin.card.fingerprintHint"))
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fingerprintGrid: some View {
        LazyVGrid(columns: fingerprintColumns, alignment: .leading, spacing: 8) {
            ForEach(Array(viewModel.fingerprintWords.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 8) {
                    Text(verbatim: "\(index + 1)")
                        .font(Typography.monoMicroBold)
                        .foregroundColor(SoyehtTheme.textComment)
                        .frame(width: 18, alignment: .trailing)
                    Text(verbatim: word)
                        .font(Typography.monoBodySemi)
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
                .background(SoyehtTheme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .accessibilityIdentifier(AccessibilityID.Household.joinRequestFingerprintWords)
    }

    private var successCheckmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(Typography.monoDisplay)
            .foregroundColor(SoyehtTheme.accentGreen)
            .frame(maxWidth: .infinity, minHeight: 118)
    }

    @ViewBuilder
    private var messageSection: some View {
        if let message = viewModel.failureMessage ?? viewModel.nonTerminalErrorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.monoSmallBold)
                    .foregroundColor(SoyehtTheme.accentAmberStrong)
                Text(message)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoyehtTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier(AccessibilityID.Household.joinRequestErrorMessage)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await viewModel.dismiss()
                }
            } label: {
                Label(localized("household.machineJoin.card.dismissButton"), systemImage: "xmark")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(JoinRequestSecondaryButtonStyle())
            .accessibilityIdentifier(AccessibilityID.Household.joinRequestDismissButton)

            Button {
                haptics.confirmTapped()
                // CRITICAL: call the sync hook BEFORE creating the Task.
                // This is what closes the lock-set race — the runtime
                // snapshot must land while we still own the main-actor
                // turn, so any concurrent owner-events / gossip update
                // that arrives next gets to render against an already-
                // pinned topId. A delayed lock (set inside `confirm()`
                // after the first `await`) would let the host rebuild
                // and orphan the VM the operator just authorized.
                onConfirmTap()
                Task {
                    await viewModel.confirm()
                }
            } label: {
                confirmButtonLabel
            }
            .buttonStyle(JoinRequestPrimaryButtonStyle(enabled: viewModel.isConfirmEnabled))
            .disabled(!viewModel.isConfirmEnabled)
            .accessibilityIdentifier(AccessibilityID.Household.joinRequestConfirmButton)
        }
    }

    @ViewBuilder
    private var confirmButtonLabel: some View {
        if viewModel.state == .authorizing {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(SoyehtTheme.buttonTextOnAccent)
                Text(localized("household.machineJoin.card.confirmButton"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        } else {
            Label(localized("household.machineJoin.card.confirmButton"), systemImage: "checkmark")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(showMemberHighlight ? SoyehtTheme.accentGreen : SoyehtTheme.bgCardBorder, lineWidth: showMemberHighlight ? 2 : 1)
            .scaleEffect(showMemberHighlight ? 1.03 : 1)
            .animation(.spring(response: 0.34, dampingFraction: 0.72), value: showMemberHighlight)
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(Typography.monoSmallBold)
                .foregroundColor(SoyehtTheme.textComment)
                .frame(width: 18)

            Text(label)
                .font(Typography.monoSmallBold)
                .foregroundColor(SoyehtTheme.textComment)
                .frame(width: 74, alignment: .leading)

            Text(verbatim: value)
                .font(Typography.monoBodyMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func runCountdown() async {
        while !Task.isCancelled {
            await viewModel.updateCountdown()
            switch viewModel.state {
            case .pending, .authorizing:
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            case .succeeded, .failed, .dismissed:
                return
            }
        }
    }

    private func handleStateChange(_ state: JoinRequestConfirmationViewModel.State) {
        switch state {
        case .succeeded:
            guard !didReportSuccess else { return }
            didReportSuccess = true
            haptics.biometricSucceeded()
            withAnimation(.easeInOut(duration: 0.18)) {
                showSuccessCheckmark = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await MainActor.run {
                    onSucceeded()
                    dismissOnce()
                }
            }
        case .dismissed:
            dismissOnce()
        case .pending, .authorizing, .failed:
            break
        }
    }

    private func triggerMemberHighlight() {
        guard memberAddedHighlightToken != 0 else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            showMemberHighlight = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    showMemberHighlight = false
                }
            }
        }
    }

    private func dismissOnce() {
        guard !didDismiss else { return }
        didDismiss = true
        onDismissed()
    }

    private var titleText: String {
        String(format: localized("household.machineJoin.card.title"), householdName)
    }

    private var timeRemainingText: String {
        let minutes = viewModel.secondsRemaining / 60
        let seconds = viewModel.secondsRemaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func localized(_ key: String) -> String {
        SoyehtCoreResources.bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

private struct JoinRequestPrimaryButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.monoBodySemi)
            .foregroundColor(enabled ? SoyehtTheme.buttonTextOnAccent : SoyehtTheme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(enabled ? SoyehtTheme.accentGreen : SoyehtTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct JoinRequestSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.monoBodySemi)
            .foregroundColor(SoyehtTheme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(SoyehtTheme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
