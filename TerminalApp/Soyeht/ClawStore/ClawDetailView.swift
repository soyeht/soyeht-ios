import SwiftUI
import SoyehtCore

// MARK: - Claw Detail View

struct ClawDetailView: View {
    @StateObject private var viewModel: ClawDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(claw: Claw) {
        _viewModel = StateObject(wrappedValue: ClawDetailViewModel(claw: claw))
    }

    private var info: ClawMockData.ClawStoreInfo {
        viewModel.storeInfo
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Nav header
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Text("<")
                                .font(Typography.monoPageTitle)
                                .foregroundColor(SoyehtTheme.accentGreen)
                        }
                        Text("claw detail")
                            .font(Typography.monoPageTitle)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }

                    // Hero Section
                    VStack(alignment: .leading, spacing: 16) {
                        // Name + version
                        HStack {
                            Text(viewModel.claw.name)
                                .font(Typography.monoHeading)
                                .foregroundColor(SoyehtTheme.textPrimary)
                            Spacer()
                            Text(viewModel.claw.displayVersion)
                                .font(Typography.monoMicroBold)
                                .foregroundColor(SoyehtTheme.historyGreen)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(SoyehtTheme.historyGreenBg)
                        }

                        // Meta: language (API) + rating (mock) + installs (mock)
                        HStack(spacing: 12) {
                            Text(viewModel.claw.language.capitalized)
                                .font(Typography.monoMicroBold)
                                .foregroundColor(SoyehtTheme.historyGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SoyehtTheme.historyGreenBg)

                            if info.rating > 0 {
                                Text("\(info.ratingStars) \(String(format: "%.1f", info.rating))")
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Text("\(info.installCount) installs")
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.textComment)
                            }
                        }

                        // Description (from API)
                        Text(viewModel.claw.description)
                            .font(Typography.monoLabelRegular)
                            .foregroundColor(SoyehtTheme.textPrimary)
                            .lineSpacing(6)
                    }
                    .padding(20)
                    .background(Color(hex: "#0A0A0A"))
                    .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))

                    // Status Section
                    Text("// status")
                        .font(Typography.monoSectionLabel)
                        .foregroundColor(SoyehtTheme.textComment)

                    VStack(spacing: 12) {
                        HStack {
                            Text("installation")
                                .font(Typography.monoLabelRegular)
                                .foregroundColor(SoyehtTheme.textSecondary)
                            Spacer()
                            Text(statusLabel)
                                .font(Typography.monoLabel)
                                .foregroundColor(statusColor)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.statusLabel)
                        }

                        // Progress / reasons block — renders when installing or blocked.
                        switch viewModel.claw.installState {
                        case .installing(let progress):
                            if let progress {
                                VStack(spacing: 8) {
                                    ProgressView(value: progress.fraction)
                                        .tint(SoyehtTheme.historyGreen)
                                        .accessibilityIdentifier(AccessibilityID.ClawDetail.progressBar)
                                    HStack {
                                        if progress.hasBytes {
                                            Text("\(progress.downloadedMB) / \(progress.totalMB) MB")
                                        }
                                        Spacer()
                                        Text("\(progress.percent)%")
                                            .accessibilityIdentifier(AccessibilityID.ClawDetail.progressPercent)
                                    }
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                }
                            }

                        case .installedButBlocked(let reasons):
                            VStack(alignment: .leading, spacing: 8) {
                                Text("// cannot create instance")
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.accentAmber)
                                ForEach(Array(reasons.enumerated()), id: \.offset) { index, reason in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("\u{00B7}")
                                            .foregroundColor(SoyehtTheme.textSecondary)
                                        Text(reason.displayMessage)
                                            .font(Typography.monoTag)
                                            .foregroundColor(SoyehtTheme.textWarning)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .accessibilityIdentifier(AccessibilityID.ClawDetail.reasonRow(index))
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: "#1A0A0A"))
                            .overlay(Rectangle().stroke(SoyehtTheme.accentAmber.opacity(0.4), lineWidth: 1))
                            .accessibilityIdentifier(AccessibilityID.ClawDetail.reasonsBlock)

                        case .installFailed(let error):
                            Text("// \(error)")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.accentRed)
                                .frame(maxWidth: .infinity, alignment: .leading)

                        case .installed, .notInstalled, .uninstalling, .unknown:
                            EmptyView()  // handled by action buttons below
                        }

                        // Action buttons
                        HStack(spacing: 10) {
                            switch viewModel.claw.installState {
                            case .installed:
                                NavigationLink(value: ClawRoute.setup(viewModel.claw)) {
                                    Text("deploy >")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(.black)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .background(SoyehtTheme.historyGreen)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.deployButton)

                                Button(action: { Task { await viewModel.uninstallClaw() } }) {
                                    Text("uninstall")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentRed)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .overlay(Rectangle().stroke(SoyehtTheme.accentRed.opacity(0.5), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.uninstallButton)
                                .disabled(viewModel.isPerformingAction)

                            case .installedButBlocked:
                                // Installed but blocked — user cannot deploy but CAN uninstall.
                                // Deploy is intentionally hidden. Reasons block above explains why.
                                Button(action: { Task { await viewModel.uninstallClaw() } }) {
                                    Text("uninstall")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentRed)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .overlay(Rectangle().stroke(SoyehtTheme.accentRed.opacity(0.5), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.uninstallButton)
                                .disabled(viewModel.isPerformingAction)

                            case .installing:
                                HStack(spacing: 8) {
                                    ProgressView().tint(SoyehtTheme.historyGreen)
                                    Text("installing...")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.historyGreen)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.installingState)

                            case .uninstalling:
                                HStack(spacing: 8) {
                                    ProgressView().tint(SoyehtTheme.accentAmber)
                                    Text("uninstalling...")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentAmber)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)

                            case .installFailed:
                                Button(action: { Task { await viewModel.installClaw() } }) {
                                    Text("retry install")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentRed)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .overlay(Rectangle().stroke(SoyehtTheme.accentRed, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.installButton)
                                .disabled(viewModel.isPerformingAction)

                            case .notInstalled:
                                Button(action: { Task { await viewModel.installClaw() } }) {
                                    Text("install")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.historyGreen)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.installButton)
                                .disabled(viewModel.isPerformingAction)

                            case .unknown:
                                Text("unknown state — refresh or contact admin")
                                    .font(Typography.monoCardTitle)
                                    .foregroundColor(SoyehtTheme.accentAmber)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                            }
                        }

                        if let error = viewModel.actionError {
                            Text(error)
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textWarning)
                        }
                    }
                    .padding(16)
                    .background(Color(hex: "#0A0A0A"))
                    .overlay(
                        Rectangle().stroke(
                            viewModel.claw.installState.isInstalled ? SoyehtTheme.historyGreen : SoyehtTheme.bgCardBorder,
                            lineWidth: 1
                        )
                    )

                    // Reviews Section
                    if !viewModel.reviews.isEmpty {
                        Text("// reviews")
                            .font(Typography.monoSectionLabel)
                            .foregroundColor(SoyehtTheme.textComment)

                        ForEach(Array(viewModel.reviews.enumerated()), id: \.offset) { _, review in
                            ReviewCard(review: review)
                        }
                    }

                    // Details Section
                    Text("// details")
                        .font(Typography.monoSectionLabel)
                        .foregroundColor(SoyehtTheme.textComment)

                    VStack(spacing: 10) {
                        DetailRow(label: "version", value: viewModel.claw.displayVersion)
                        DetailRow(label: "binary size", value: viewModel.claw.displayBinarySize)
                        DetailRow(label: "min ram", value: viewModel.claw.displayMinRAM)
                        DetailRow(label: "license", value: viewModel.claw.displayLicense)
                        DetailRow(label: "last updated", value: viewModel.claw.displayUpdatedAt)
                    }
                    .padding(16)
                    .background(Color(hex: "#0A0A0A"))
                    .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))

                    // Footer
                    Text("installed on \(viewModel.installedServerCount) of your servers")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textComment)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .navigationBarHidden(true)
    }

    private var statusLabel: String {
        switch viewModel.claw.installState {
        case .installed:             return "installed"
        case .installedButBlocked:   return "installed \u{2022} blocked"
        case .installing:            return "installing..."
        case .uninstalling:          return "uninstalling..."
        case .installFailed:         return "failed"
        case .notInstalled:          return "not installed"
        case .unknown:               return "unknown"
        }
    }

    private var statusColor: Color {
        switch viewModel.claw.installState {
        case .installed:             return SoyehtTheme.historyGreen
        case .installedButBlocked:   return SoyehtTheme.accentAmber
        case .installing:            return SoyehtTheme.accentAmber
        case .uninstalling:          return SoyehtTheme.accentAmber
        case .installFailed:         return SoyehtTheme.accentRed
        case .notInstalled:          return SoyehtTheme.textComment
        case .unknown:               return SoyehtTheme.accentAmber
        }
    }
}

// MARK: - Review Card

private struct ReviewCard: View {
    let review: ClawMockData.ClawReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(review.author)
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Spacer()
                Text(String(format: "%.1f", review.rating))
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.historyGreen)
            }

            Text("\"\(review.text)\"")
                .font(Typography.monoTag)
                .italic()
                .foregroundColor(SoyehtTheme.textPrimary)
                .lineSpacing(4)

            Text(review.timeAgo)
                .font(Typography.monoMicro)
                .foregroundColor(SoyehtTheme.textTertiary)
        }
        .padding(16)
        .background(Color(hex: "#0A0A0A"))
        .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textComment)
            Spacer()
            Text(value)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textPrimary)
        }
    }
}
