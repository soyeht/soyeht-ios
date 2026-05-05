import SwiftUI
import SoyehtCore

// MARK: - Claw Detail View

struct ClawDetailView: View {
    @StateObject private var viewModel: ClawDetailViewModel
    let context: ServerContext
    @Environment(\.dismiss) private var dismiss

    init(claw: Claw, context: ServerContext) {
        self.context = context
        _viewModel = StateObject(wrappedValue: ClawDetailViewModel(claw: claw, context: context))
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
                            Text(verbatim: "<")
                                .font(Typography.monoPageTitle)
                                .foregroundColor(SoyehtTheme.accentGreen)
                        }
                        Text("clawDetail.title")
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
                                Text(verbatim: "\(info.ratingStars) \(String(format: "%.1f", info.rating))")
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Text(LocalizedStringResource(
                                    "claw.featured.installsCount",
                                    defaultValue: "\(info.installCount) installs",
                                    comment: "Meta row — total install count."
                                ))
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
                    .background(SoyehtTheme.bgPrimary)
                    .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))

                    // Status Section
                    Text("clawDetail.section.status")
                        .font(Typography.monoSectionLabel)
                        .foregroundColor(SoyehtTheme.textComment)

                    VStack(spacing: 12) {
                        HStack {
                            Text("clawDetail.label.installation")
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
                                            Text(verbatim: "\(progress.downloadedMB) / \(progress.totalMB) MB")
                                        }
                                        Spacer()
                                        Text(verbatim: "\(progress.percent)%")
                                            .accessibilityIdentifier(AccessibilityID.ClawDetail.progressPercent)
                                    }
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                }
                            }

                        case .installedButBlocked(let reasons):
                            VStack(alignment: .leading, spacing: 8) {
                                Text("clawDetail.blocked.header")
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.accentAmber)
                                ForEach(Array(reasons.enumerated()), id: \.offset) { index, reason in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(verbatim: "\u{00B7}")
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
                            .background(SoyehtTheme.bgCard)
                            .overlay(Rectangle().stroke(SoyehtTheme.accentAmberStrong, lineWidth: 1))
                            .accessibilityIdentifier(AccessibilityID.ClawDetail.reasonsBlock)

                        case .installFailed(let error):
                            Text(verbatim: "// \(error)")
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
                                NavigationLink(value: ClawRoute.setup(viewModel.claw, serverId: context.serverId)) {
                                    Text("clawDetail.button.deploy")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.buttonTextOnAccent)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .background(SoyehtTheme.historyGreen)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.deployButton)

                                Button(action: { Task { await viewModel.uninstallClaw() } }) {
                                    Text("clawDetail.button.uninstall")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentRed)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .overlay(Rectangle().stroke(SoyehtTheme.accentRedStrong, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.uninstallButton)
                                .disabled(viewModel.isPerformingAction)

                            case .installedButBlocked:
                                // Installed but blocked — user cannot deploy but CAN uninstall.
                                // Deploy is intentionally hidden. Reasons block above explains why.
                                Button(action: { Task { await viewModel.uninstallClaw() } }) {
                                    Text("clawDetail.button.uninstall")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentRed)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .overlay(Rectangle().stroke(SoyehtTheme.accentRedStrong, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.uninstallButton)
                                .disabled(viewModel.isPerformingAction)

                            case .installing:
                                HStack(spacing: 8) {
                                    ProgressView().tint(SoyehtTheme.historyGreen)
                                    Text("claw.card.state.installing")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.historyGreen)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .accessibilityIdentifier(AccessibilityID.ClawDetail.installingState)

                            case .uninstalling:
                                HStack(spacing: 8) {
                                    ProgressView().tint(SoyehtTheme.accentAmber)
                                    Text("claw.card.state.uninstalling")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentAmber)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)

                            case .installFailed:
                                Button(action: { Task { await viewModel.installClaw() } }) {
                                    Text("claw.featured.action.retryInstall")
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
                                    Text("claw.card.action.install")
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
                                Text("clawDetail.state.unknown")
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
                    .background(SoyehtTheme.bgPrimary)
                    .overlay(
                        Rectangle().stroke(
                            viewModel.claw.installState.isInstalled ? SoyehtTheme.historyGreen : SoyehtTheme.bgCardBorder,
                            lineWidth: 1
                        )
                    )

                    // Reviews Section
                    if !viewModel.reviews.isEmpty {
                        Text("clawDetail.section.reviews")
                            .font(Typography.monoSectionLabel)
                            .foregroundColor(SoyehtTheme.textComment)

                        ForEach(Array(viewModel.reviews.enumerated()), id: \.offset) { _, review in
                            ReviewCard(review: review)
                        }
                    }

                    // Details Section
                    Text("clawDetail.section.details")
                        .font(Typography.monoSectionLabel)
                        .foregroundColor(SoyehtTheme.textComment)

                    VStack(spacing: 10) {
                        DetailRow(label: "clawDetail.detailRow.version", value: viewModel.claw.displayVersion)
                        DetailRow(label: "clawDetail.detailRow.binarySize", value: viewModel.claw.displayBinarySize)
                        DetailRow(label: "clawDetail.detailRow.minRam", value: viewModel.claw.displayMinRAM)
                        DetailRow(label: "clawDetail.detailRow.license", value: viewModel.claw.displayLicense)
                        DetailRow(label: "clawDetail.detailRow.lastUpdated", value: viewModel.claw.displayUpdatedAt)
                    }
                    .padding(16)
                    .background(SoyehtTheme.bgPrimary)
                    .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))

                    // Footer
                    Text(LocalizedStringResource(
                        "clawDetail.footer.installedOn",
                        defaultValue: "installed on \(viewModel.installedServerCount) of your servers",
                        comment: "Footer count — how many paired servers have this claw. %lld = count."
                    ))
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
        case .installed:             return String(localized: "claw.card.state.installed", comment: "Claw state label — installed.")
        case .installedButBlocked:   return String(localized: "claw.card.state.installedBlocked", comment: "Claw state label — installed but blocked.")
        case .installing:            return String(localized: "claw.card.state.installing", comment: "Claw state label — install in progress.")
        case .uninstalling:          return String(localized: "claw.card.state.uninstalling", comment: "Claw state label — uninstall in progress.")
        case .installFailed:         return String(localized: "clawDetail.state.failed", comment: "Claw state label — install failed.")
        case .notInstalled:          return String(localized: "claw.card.state.notInstalled", comment: "Claw state label — not installed.")
        case .unknown:               return String(localized: "claw.card.state.unknown", comment: "Claw state label — unknown.")
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

            Text(verbatim: "\"\(review.text)\"")
                .font(Typography.monoTag)
                .italic()
                .foregroundColor(SoyehtTheme.textPrimary)
                .lineSpacing(4)

            Text(review.timeAgo)
                .font(Typography.monoMicro)
                .foregroundColor(SoyehtTheme.textTertiary)
        }
        .padding(16)
        .background(SoyehtTheme.bgPrimary)
        .overlay(Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1))
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let label: LocalizedStringKey
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
