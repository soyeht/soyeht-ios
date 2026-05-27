import SwiftUI
import SoyehtCore

// MARK: - Claw Detail View

struct ClawDetailView: View {
    @StateObject private var viewModel: ClawDetailViewModel
    let installTarget: ClawInstallTarget
    let resolution: ClawInstallTargetResolver.Resolution
    @Environment(\.dismiss) private var dismiss

    /// PR-3 init. The resolver computes the `ClawAPITarget` and the
    /// gating state used to decide whether to show the Deploy button.
    ///
    /// `pairedServerCountProvider` is intentionally left at its default
    /// in `SoyehtCore` — the per-server footer never reads it since
    /// PR-2's host-collapse comment landed, and removing the public
    /// parameter from `ClawDetailViewModel` is left for a follow-up
    /// (per PR-3 review comments).
    init(claw: Claw, installTarget: ClawInstallTarget) {
        self.installTarget = installTarget
        let resolution = ClawInstallTargetResolver.resolve(installTarget)
        self.resolution = resolution
        let target: ClawAPITarget = resolution.apiTarget ?? .household
        _viewModel = StateObject(wrappedValue: ClawDetailViewModel(claw: claw, target: target))
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
                                if let deployRoute {
                                    NavigationLink(value: deployRoute) {
                                        Text("clawDetail.button.deploy")
                                            .font(Typography.monoCardTitle)
                                            .foregroundColor(SoyehtTheme.buttonTextOnAccent)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 36)
                                            .background(SoyehtTheme.historyGreen)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.ClawDetail.deployButton)
                                }

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

                        // PR-3: explain inline when the Deploy button is
                        // intentionally hidden because this server can't
                        // be deployed to directly. Only render for states
                        // where the user would otherwise expect Deploy —
                        // installed or installed-but-blocked.
                        if !resolution.supportsDeploy, viewModel.claw.installState.isInstalled {
                            Text(LocalizedStringResource(
                                "clawDetail.deploy.unavailable.body",
                                defaultValue: "Direct deploy is not available for this Mac yet.",
                                comment: "Inline message shown on the Claw detail screen when the Deploy button is intentionally hidden because the server cannot be deployed to directly."
                            ))
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
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

                    // Footer — target-specific, not aggregate.
                    //
                    // The previous copy ("installed on N of your servers")
                    // tried to summarise install state across every paired
                    // server but read the count from `SessionStore.pairedServers`
                    // alone, so it (a) excluded Macs paired via the household
                    // flow and (b) reported the total servers, not the
                    // servers where this claw is actually installed. With
                    // multiple servers in a household, replacing the total
                    // by a registry-wide count made the bug worse, not
                    // better.
                    //
                    // Until the engine exposes a real per-server install
                    // aggregate, we only render the install state of the
                    // CURRENT target (the server you tapped to enter this
                    // detail view). For the household target, we hide the
                    // footer entirely — a future API surface (e.g.
                    // `GET /api/v1/household/claws/{name}/installed-on`)
                    // can repopulate it with truthful per-server data.
                    // PR-3: footer renders only when we have a real
                    // per-server context. For the single-Mac household
                    // fallback the catalog browse and install routes
                    // work via PoP, but "installed on this server" is
                    // a per-server statement that the aggregate
                    // endpoint can't truthfully back yet.
                    switch resolution {
                    case .server:
                        Text(LocalizedStringResource(
                            viewModel.claw.installState.isInstalled
                                ? "clawDetail.footer.installedOnThisServer"
                                : "clawDetail.footer.notInstalledOnThisServer",
                            defaultValue: viewModel.claw.installState.isInstalled
                                ? "installed on this server"
                                : "not installed on this server",
                            comment: "Footer status for a single server target."
                        ))
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textComment)
                            .frame(maxWidth: .infinity, alignment: .center)
                    case .householdFallback, .unavailable:
                        EmptyView()
                    }
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

    private var deployRoute: ClawRoute? {
        // PR-3: Deploy needs `createInstance(_, context:)` which requires
        // a `ServerContext`. Only the `.server` resolution carries one;
        // the household fallback and unavailable cases must not offer
        // Deploy. Copy "clawDetail.deploy.unavailable.body" is rendered
        // inline by the caller when this returns nil and the user is in
        // a state where they could otherwise expect Deploy.
        guard resolution.supportsDeploy else { return nil }
        return .setup(viewModel.claw, serverId: installTarget.serverID)
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
