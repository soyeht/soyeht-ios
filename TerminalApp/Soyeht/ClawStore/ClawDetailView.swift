import SwiftUI
import SoyehtCore

// MARK: - Claw Detail View

struct ClawDetailView: View {
    let claw: Claw
    let installTarget: ClawInstallTarget
    let resolution: ClawInstallTargetResolver.Resolution
    @Environment(\.dismiss) private var dismiss

    /// PR-3 init. The resolver computes the `ClawAPITarget` and the
    /// gating state used to decide whether to show the Deploy button.
    ///
    /// `pairedServerCountProvider` is intentionally left at the
    /// SoyehtCore default (`ServerStore` canonical inventory) — the
    /// per-server footer never reads it on iOS since PR-2's
    /// host-collapse comment landed, and removing the public parameter
    /// from `ClawDetailViewModel` is left for a follow-up.
    init(claw: Claw, installTarget: ClawInstallTarget) {
        self.claw = claw
        self.installTarget = installTarget
        let resolution = ClawInstallTargetResolver.resolve(installTarget)
        self.resolution = resolution
    }

    var body: some View {
        switch resolution {
        case .unavailable:
            MacClawUnavailableView(serverDisplayName: serverDisplayName, onBack: { dismiss() })
        case .server, .householdEndpoint:
            ResolvedClawDetailView(
                claw: claw,
                installTarget: installTarget,
                resolution: resolution
            )
        }
    }

    private var serverDisplayName: String? {
        ServerRegistry.shared.server(id: installTarget.serverID)?.displayName
    }
}

private struct ResolvedClawDetailView: View {
    @StateObject private var viewModel: ClawDetailViewModel
    @StateObject private var readinessObserver: GuestImageReadinessObserver
    let installTarget: ClawInstallTarget
    let resolution: ClawInstallTargetResolver.Resolution
    @Environment(\.dismiss) private var dismiss

    init(
        claw: Claw,
        installTarget: ClawInstallTarget,
        resolution: ClawInstallTargetResolver.Resolution
    ) {
        self.installTarget = installTarget
        self.resolution = resolution
        _viewModel = StateObject(wrappedValue: ClawDetailViewModel(claw: claw, machineTarget: resolution))
        _readinessObserver = StateObject(wrappedValue: GuestImageReadinessObserver(
            initialState: GuestImageReadinessClient.initialState(
                for: installTarget,
                resolution: resolution
            )
        ))
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

                        // Meta: language (API)
                        HStack(spacing: 12) {
                            Text(viewModel.claw.language.capitalized)
                                .font(Typography.monoMicroBold)
                                .foregroundColor(SoyehtTheme.historyGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SoyehtTheme.historyGreenBg)
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

                        // Installability (theyos #88) takes precedence over
                        // guest-image readiness: a claw the backend says can
                        // never be installed must not show a "preparing Mac"
                        // gate or an Install button.
                        if case .unavailable(let code, let message) = viewModel.claw.installability {
                            clawUnavailableCard(code: code, message: message)
                        } else if !readinessObserver.state.allowsInstall {
                            guestImageGateCard
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
                            if readinessObserver.state.allowsInstall {
                                Text(verbatim: "// \(error)")
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.accentRed)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                        case .installed, .notInstalled, .uninstalling, .unknown:
                            EmptyView()  // handled by action buttons below
                        }

                        // Action buttons
                        let actions = actionAvailability
                        HStack(spacing: 10) {
                            if actions.showsDeploy, let deployRoute {
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
                                .disabled(!actionPolicy.isEnabled(.deploy))
                            }

                            if actions.showsUninstall {
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
                                .disabled(!actionPolicy.isEnabled(.uninstall))
                            }

                            if actions.showsInstallingProgress {
                                HStack(spacing: 8) {
                                    ProgressView().tint(SoyehtTheme.historyGreen)
                                    Text("claw.card.state.installing")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.historyGreen)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                        .accessibilityIdentifier(AccessibilityID.ClawDetail.installingState)
                            }

                            if actions.showsUninstallingProgress {
                                HStack(spacing: 8) {
                                    ProgressView().tint(SoyehtTheme.accentAmber)
                                    Text("claw.card.state.uninstalling")
                                        .font(Typography.monoCardTitle)
                                        .foregroundColor(SoyehtTheme.accentAmber)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                            }

                            if actions.showsRetryInstall {
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
                                .disabled(!actionPolicy.isEnabled(.retryInstall))
                            }

                            if actions.showsInstall {
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
                                .disabled(!actionPolicy.isEnabled(.install))
                            }

                            if actions.showsUnknownState {
                                Text("clawDetail.state.unknown")
                                    .font(Typography.monoCardTitle)
                                    .foregroundColor(SoyehtTheme.accentAmber)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                            }
                        }

                        if readinessObserver.state.allowsInstall, let error = viewModel.actionError {
                            Text(error)
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textWarning)
                        }

                        // PR-3: explain inline when the Deploy button is
                        // intentionally hidden because this server can't
                        // be deployed to directly. Only render for states
                        // where the user would otherwise expect Deploy —
                        // installed or installed-but-blocked.
                        if actions.showsDeployUnavailableNotice {
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
                    // per-server context. For the PoP endpoint route,
                    // catalog browse and install target the selected
                    // Mac, but "installed on this server" is still
                    // backed by the household Claw shape rather than a
                    // mobile `ServerContext`, so keep the footer hidden
                    // until the engine exposes a first-class per-server
                    // install aggregate.
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
                    case .householdEndpoint, .unavailable:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .navigationBarHidden(true)
        .task {
            readinessObserver.start(target: installTarget, resolution: resolution)
        }
        .onDisappear {
            readinessObserver.stop()
        }
    }

    /// Card shown in place of the Install CTA when the backend reports a claw
    /// is not installable (theyos #88). Copy is keyed off the machine-readable
    /// `reasonCode` — never parsed from the backend message, which is surfaced
    /// only as an optional secondary detail.
    @ViewBuilder
    private func clawUnavailableCard(code: ClawUnavailableReasonCode, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.unavailableTitle(for: code))
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.accentAmber)
            if let message, !message.isEmpty {
                Text(verbatim: message)
                    .font(Typography.monoMicro)
                    .foregroundColor(SoyehtTheme.textComment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoyehtTheme.bgCard)
        .overlay(Rectangle().stroke(SoyehtTheme.accentAmberStrong, lineWidth: 1))
        .accessibilityIdentifier(AccessibilityID.ClawDetail.unavailableCard)
    }

    /// Localized, reason-coded copy. Unknown / future codes fall back to a
    /// generic line so a newer backend never leaks a raw enum name to the UI.
    static func unavailableTitle(for code: ClawUnavailableReasonCode) -> LocalizedStringResource {
        switch code {
        case .catalogOnly:
            return LocalizedStringResource(
                "clawDetail.unavailable.catalogOnly",
                defaultValue: "Not available to install yet",
                comment: "Shown when a claw exists in the catalog for discovery only and cannot be installed."
            )
        case .detectedUnverified:
            return LocalizedStringResource(
                "clawDetail.unavailable.detectedUnverified",
                defaultValue: "This Claw is still being verified",
                comment: "Shown when a claw has been detected but not yet verified for install."
            )
        case .noInstallPlan:
            return LocalizedStringResource(
                "clawDetail.unavailable.noInstallPlan",
                defaultValue: "Install plan unavailable",
                comment: "Shown when a claw qualifies by tier but has no install path (manifest inconsistency)."
            )
        case .unknown:
            return LocalizedStringResource(
                "clawDetail.unavailable.generic",
                defaultValue: "Not available to install",
                comment: "Generic fallback shown when a claw is not installable for an unrecognized reason."
            )
        }
    }

    @ViewBuilder
    private var guestImageGateCard: some View {
        switch readinessObserver.state {
        case .allowed:
            EmptyView()
        case .checking:
            readinessCard(
                title: LocalizedStringResource(
                    "clawDetail.guestImage.checking.title",
                    defaultValue: "Checking this Mac",
                    comment: "Title shown while iPhone checks whether a Mac is ready for Claw install."
                ),
                body: LocalizedStringResource(
                    "clawDetail.guestImage.checking.body",
                    defaultValue: "Install will be available when this Mac reports that it is ready.",
                    comment: "Body shown while iPhone checks whether a Mac is ready for Claw install."
                ),
                tone: .neutral
            )
        case .unavailable:
            readinessCard(
                title: LocalizedStringResource(
                    "clawDetail.guestImage.unavailable.title",
                    defaultValue: "Cannot check this Mac yet",
                    comment: "Title shown when iPhone cannot reach a Mac's bootstrap status."
                ),
                body: LocalizedStringResource(
                    "clawDetail.guestImage.unavailable.body",
                    defaultValue: "Open Soyeht on the Mac, then try again from this screen.",
                    comment: "Body shown when iPhone cannot reach a Mac's bootstrap status."
                ),
                tone: .warning
            )
        case .blocked(let readiness):
            switch readiness {
            case .notStarted:
                readinessCard(
                    title: LocalizedStringResource(
                        "clawDetail.guestImage.notStarted.title",
                        defaultValue: "Setup required on this Mac",
                        comment: "Title shown when a Mac has not prepared its guest image yet."
                    ),
                    body: LocalizedStringResource(
                        "clawDetail.guestImage.notStarted.body",
                        defaultValue: "Soyeht can prepare this Mac remotely. The Mac will download and prepare the macOS base image; this usually takes 30 minutes or more.",
                        comment: "Body shown when a Mac has not prepared its guest image yet."
                    ),
                    actionTitle: LocalizedStringResource(
                        "clawDetail.guestImage.prepare.button",
                        defaultValue: "Prepare this Mac",
                        comment: "Button that starts remote guest-image preparation on the selected Mac."
                    ),
                    action: { startGuestImagePreparation(force: false) },
                    tone: .warning
                )
            case .inProgress(let phase):
                readinessCard(
                    title: LocalizedStringResource(
                        "clawDetail.guestImage.inProgress.title",
                        defaultValue: "Preparing this Mac",
                        comment: "Title shown while a Mac prepares its guest image."
                    ),
                    body: phaseLabel(phase),
                    footnote: LocalizedStringResource(
                        "clawDetail.guestImage.inProgress.footnote",
                        defaultValue: "Install will be available when this Mac finishes preparing. This usually takes 30 minutes or more.",
                        comment: "Footnote shown while a Mac prepares its guest image."
                    ),
                    tone: .neutral
                )
            case .failed(let error, let code):
                // Reason-coded recovery: copy from GuestImageFailureCopy; CTA/action
                // from the shared policy. Raw `error` stays behind Details.
                if let presentation = GuestImageRecoveryPolicy.presentation(for: readiness) {
                    readinessCard(
                        title: GuestImageFailureCopy.title(for: code),
                        body: GuestImageFailureCopy.body(for: code),
                        footnote: GuestImageFailureCopy.secondaryInstruction(for: code),
                        detail: error,
                        actionTitle: GuestImageFailureCopy.primaryLabel(for: presentation.cta),
                        action: guestImageRecoveryHandler(for: presentation.cta),
                        tone: .error
                    )
                }
            case .notApplicable, .ready:
                EmptyView()
            }
        }
    }

    private enum ReadinessTone {
        case neutral
        case warning
        case error

        var color: Color {
            switch self {
            case .neutral: return SoyehtTheme.accentAmber
            case .warning: return SoyehtTheme.accentAmber
            case .error: return SoyehtTheme.accentRed
            }
        }
    }

    private func readinessCard(
        title: LocalizedStringResource,
        body: LocalizedStringResource,
        footnote: LocalizedStringResource? = nil,
        detail: String? = nil,
        actionTitle: LocalizedStringResource? = nil,
        action: (() -> Void)? = nil,
        tone: ReadinessTone
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if case .checking = readinessObserver.state {
                    ProgressView()
                        .tint(tone.color)
                        .scaleEffect(0.7)
                }
                Text(title)
                    .font(Typography.monoTag)
                    .foregroundColor(tone.color)
            }

            Text(body)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textWarning)
                .fixedSize(horizontal: false, vertical: true)

            if let footnote {
                Text(footnote)
                    .font(Typography.monoMicro)
                    .foregroundColor(SoyehtTheme.textComment)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Raw daemon/engine text is never a primary line — it lives behind a
            // discreet "Details" disclosure as secondary detail (Apple-grade copy
            // comes from the reason-coded title/body above).
            if let rawDetail = GuestImageFailureCopy.combinedRawDetail(detail: detail, prepareError: readinessObserver.prepareError) {
                DisclosureGroup {
                    Text(verbatim: rawDetail)
                        .font(Typography.monoMicro)
                        .foregroundColor(SoyehtTheme.textComment)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(LocalizedStringResource(
                        "clawDetail.guestImage.details.disclosure",
                        defaultValue: "Details",
                        comment: "Disclosure toggle revealing the raw engine error as secondary detail."
                    ))
                    .font(Typography.monoMicro)
                    .foregroundColor(SoyehtTheme.textComment)
                }
                .tint(SoyehtTheme.textComment)
                .accessibilityIdentifier(AccessibilityID.ClawDetail.guestImageDetailsDisclosure)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if readinessObserver.isPreparing {
                            ProgressView()
                                .tint(tone.color)
                                .scaleEffect(0.65)
                        }
                        Text(actionTitle)
                            .font(Typography.monoCardTitle)
                    }
                    .foregroundColor(tone.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .overlay(Rectangle().stroke(tone.color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(readinessObserver.isPreparing)
                .accessibilityIdentifier(AccessibilityID.ClawDetail.prepareGuestImageButton)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoyehtTheme.bgCard)
        .overlay(Rectangle().stroke(tone.color.opacity(0.75), lineWidth: 1))
        .accessibilityIdentifier(AccessibilityID.ClawDetail.guestImageGate)
    }

    private func startGuestImagePreparation(force: Bool) {
        Task {
            await readinessObserver.prepare(
                target: installTarget,
                resolution: resolution,
                force: force
            )
        }
    }

    /// Re-check Mac status WITHOUT issuing a prepare (the "Check Again" action).
    private func refreshGuestImageStatus() {
        Task {
            await readinessObserver.refreshStatus(
                target: installTarget,
                resolution: resolution
            )
        }
    }

    /// Maps the shared recovery CTA to its handler. `.checkAgain` only refreshes
    /// status, so host-side blockers never issue a prepare POST.
    private func guestImageRecoveryHandler(for cta: GuestImageRecoveryCTA) -> (() -> Void)? {
        switch cta {
        case .prepare:
            return { startGuestImagePreparation(force: true) }
        case .checkAgain:
            return { refreshGuestImageStatus() }
        case .none:
            return nil
        }
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
        // the household endpoint and unavailable cases must not offer
        // Deploy. Copy "clawDetail.deploy.unavailable.body" is rendered
        // inline by the caller when this returns nil and the user is in
        // a state where they could otherwise expect Deploy.
        guard resolution.supportsDeploy else { return nil }
        guard readinessObserver.state.allowsInstall else { return nil }
        return .setup(viewModel.claw, serverId: installTarget.serverID)
    }

    private var actionAvailability: ClawDetailActionAvailability {
        ClawDetailActionAvailability(
            installState: viewModel.claw.installState,
            installability: viewModel.claw.installability,
            allowsInstall: readinessObserver.state.allowsInstall,
            supportsDeploy: resolution.supportsDeploy
        )
    }

    /// Visibility stays on the facade above; this drives only ENABLEMENT, folding
    /// in the in-flight axis so install/retry/deploy/uninstall disable while an
    /// action runs. iOS detail has no terminal entry point (canOpenTerminal: false).
    private var actionPolicy: ClawActionPolicy {
        ClawActionPolicy(
            ClawActionPolicy.Input(
                installState: viewModel.claw.installState,
                installability: viewModel.claw.installability,
                hostAllowsInstall: readinessObserver.state.allowsInstall,
                supportsDeploy: resolution.supportsDeploy,
                actionInFlight: viewModel.isPerformingAction,
                canOpenTerminal: false
            )
        )
    }

    private func phaseLabel(_ phase: String) -> LocalizedStringResource {
        switch phase {
        case "download_ipsw":
            return LocalizedStringResource(
                "clawDetail.guestImage.phase.downloadIpsw",
                defaultValue: "Downloading macOS installer",
                comment: "Guest-image preparation phase label."
            )
        case "create_disk":
            return LocalizedStringResource(
                "clawDetail.guestImage.phase.createDisk",
                defaultValue: "Creating virtual disk",
                comment: "Guest-image preparation phase label."
            )
        case "install_macos":
            return LocalizedStringResource(
                "clawDetail.guestImage.phase.installMacos",
                defaultValue: "Installing macOS",
                comment: "Guest-image preparation phase label."
            )
        case "provision":
            return LocalizedStringResource(
                "clawDetail.guestImage.phase.provision",
                defaultValue: "Provisioning",
                comment: "Guest-image preparation phase label."
            )
        case "create_snapshot":
            return LocalizedStringResource(
                "clawDetail.guestImage.phase.createSnapshot",
                defaultValue: "Finalizing",
                comment: "Guest-image preparation phase label."
            )
        default:
            return LocalizedStringResource(
                "clawDetail.guestImage.phase.unknown",
                defaultValue: "Preparing",
                comment: "Fallback guest-image preparation phase label."
            )
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
