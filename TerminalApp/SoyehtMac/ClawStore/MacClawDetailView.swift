import SwiftUI
import SoyehtCore

/// Detail view for a single Claw. Shows the catalog metadata (description,
/// language, minimum RAM, license, version), the current install state,
/// and the relevant lifecycle action (install / retry / uninstall /
/// deploy). Deploy opens `MacClawSetupView` via the shared NavigationStack.
struct MacClawDetailView: View {
    let context: ServerContext
    let target: ClawMachineTarget
    /// Called after any install/uninstall action so the parent store view model
    /// can reload and begin its own window-lifetime polling (surviving back-nav).
    var onInstallStateChanged: (() -> Void)?
    var onOpenTerminal: ((String) -> Void)?
    @StateObject private var viewModel: ClawDetailViewModel
    /// P6/A: the same macOS guest-image readiness gate as the catalog root, so
    /// the detail's install/retry/deploy actions respect readiness too (they
    /// all depend on the engine's guest image). Observed so it stays reactive
    /// while the detail is open. Owned by the root view.
    @ObservedObject private var readiness: MacGuestImageReadinessModel

    init(
        claw: Claw,
        context: ServerContext,
        target: ClawMachineTarget? = nil,
        readiness: MacGuestImageReadinessModel,
        onInstallStateChanged: (() -> Void)? = nil,
        onOpenTerminal: ((String) -> Void)? = nil
    ) {
        let target = target ?? .server(context)
        self.context = context
        self.target = target
        self.onInstallStateChanged = onInstallStateChanged
        self.onOpenTerminal = onOpenTerminal
        _readiness = ObservedObject(wrappedValue: readiness)
        _viewModel = StateObject(wrappedValue: ClawDetailViewModel(claw: claw, machineTarget: target))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                // Installability (theyos #88) takes precedence over the
                // install-state banner/actions: a claw the backend marks
                // non-installable shows a reason-coded notice and no
                // Install/Retry button.
                if case .unavailable(let code, let message) = viewModel.claw.installability {
                    unavailableNotice(code: code, message: message)
                } else {
                    stateBanner
                    MacGuestImageRecoveryBanner(
                        state: readiness.state,
                        onCheckAgain: { Task { await readiness.recheck() } },
                        onPrepare: { Task { await readiness.prepare() } },
                        isRechecking: readiness.isRechecking,
                        isPreparing: readiness.isPreparing
                    )
                    actions
                }
                details
                if viewModel.isPolling {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("claw.detail.status.polling")
                            .font(MacTypography.Fonts.clawDetailPolling)
                            .foregroundColor(MacClawStoreTheme.textMuted)
                    }
                }
                if let actionError = viewModel.actionError {
                    Text(actionError)
                        .font(MacTypography.Fonts.clawDetailError)
                        .foregroundColor(MacClawStoreTheme.textWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(MacClawStoreTheme.bgPrimary)
        .navigationTitle(viewModel.claw.name)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(viewModel.claw.name)
                    .font(MacTypography.Fonts.clawDetailHeroTitle)
                    .foregroundColor(MacClawStoreTheme.textPrimary)
                Text(verbatim: "v\(viewModel.claw.displayVersion)")
                    .font(MacTypography.Fonts.clawDetailVersion)
                    .foregroundColor(MacClawStoreTheme.textMuted)
            }
            Text(viewModel.claw.description)
                .font(MacTypography.Fonts.clawDetailBody)
                .foregroundColor(MacClawStoreTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch viewModel.claw.installState {
        case .installed:
            StateBanner(color: MacClawStoreTheme.statusGreen, icon: "checkmark.circle.fill", title: "claw.detail.banner.installed")
        case .installedButBlocked(let reasons):
            VStack(alignment: .leading, spacing: 6) {
                StateBanner(color: MacClawStoreTheme.accentAmber, icon: "exclamationmark.triangle.fill", title: "claw.detail.banner.installedButBlocked")
                ForEach(reasons, id: \.self) { reason in
                    (Text(verbatim: "• ") + Text(reason.displayMessage))
                        .font(MacTypography.Fonts.clawDetailMeta)
                        .foregroundColor(MacClawStoreTheme.textSecondary)
                }
            }
        case .installing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                StateBanner(color: MacClawStoreTheme.statusGreen, icon: "arrow.down.circle", title: "claw.detail.banner.installing")
                if let p = progress {
                    ProgressView(value: p.fraction).tint(MacClawStoreTheme.statusGreen)
                    Text(verbatim: "\(p.phase.rawValue) · \(p.percent)%")
                        .font(MacTypography.Fonts.clawDetailMeta)
                        .foregroundColor(MacClawStoreTheme.textMuted)
                }
            }
        case .uninstalling:
            StateBanner(color: MacClawStoreTheme.accentAmber, icon: "minus.circle", title: "claw.detail.banner.uninstalling")
        case .installFailed(let err):
            VStack(alignment: .leading, spacing: 6) {
                StateBanner(color: MacClawStoreTheme.textWarning, icon: "xmark.octagon.fill", title: "claw.detail.banner.installFailed")
                DisclosureGroup("claw.detail.disclosure.viewLog") {
                    ScrollView {
                        Text(err)
                            .font(MacTypography.Fonts.clawDetailLog)
                            .foregroundColor(MacClawStoreTheme.textMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .font(MacTypography.Fonts.clawDetailMeta)
                .foregroundColor(MacClawStoreTheme.textSecondary)
            }
        case .notInstalled:
            StateBanner(color: MacClawStoreTheme.textMuted, icon: "circle.dashed", title: "claw.detail.banner.notInstalled")
        case .unknown:
            StateBanner(color: MacClawStoreTheme.textWarning, icon: "questionmark.circle.fill", title: "claw.detail.banner.unknown")
        }
    }

    @ViewBuilder
    private var actions: some View {
        let actionAvailability = ClawDetailActionAvailability(
            installState: viewModel.claw.installState,
            installability: viewModel.claw.installability,
            allowsInstall: readiness.state.allowsInstall,
            supportsDeploy: target.supportsDeploy
        )
        // Visibility stays on the facade above; this drives only ENABLEMENT,
        // folding in the in-flight axis (and the terminal entry point) so the
        // detail actions disable while another action runs.
        let actionPolicy = ClawActionPolicy(
            ClawActionPolicy.Input(
                installState: viewModel.claw.installState,
                installability: viewModel.claw.installability,
                hostAllowsInstall: readiness.state.allowsInstall,
                supportsDeploy: target.supportsDeploy,
                actionInFlight: viewModel.isPerformingAction,
                canOpenTerminal: onOpenTerminal != nil
            )
        )

        HStack(spacing: 8) {
            if actionAvailability.showsInstall {
                Button {
                    Task { await viewModel.installClaw(); onInstallStateChanged?() }
                } label: {
                    Text("claw.detail.button.install")
                        .font(MacTypography.Fonts.clawActionButton)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!actionPolicy.isEnabled(.install))
            }

            if actionAvailability.showsDeploy {
                NavigationLink(value: ClawRoute.setup(viewModel.claw, serverId: context.serverId)) {
                    Text("claw.detail.button.createInstance")
                        .font(MacTypography.Fonts.clawActionButton)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!actionPolicy.isEnabled(.deploy))

                Button {
                    onOpenTerminal?(viewModel.claw.name)
                } label: {
                    Label {
                        Text(LocalizedStringResource(
                            "claw.detail.button.openTerminal",
                            defaultValue: "Open Terminal",
                            comment: "Button on macOS Claw detail that opens a terminal pane attached to an installed claw."
                        ))
                        .font(MacTypography.Fonts.clawActionButton)
                    } icon: {
                        Image(systemName: "terminal")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!actionPolicy.isEnabled(.openTerminal))
                .accessibilityIdentifier("soyeht.macClawDetail.openTerminal")
            }

            if actionAvailability.showsUninstall {
                Button {
                    Task { await viewModel.uninstallClaw(); onInstallStateChanged?() }
                } label: {
                    Text("claw.detail.button.uninstall")
                        .font(MacTypography.Fonts.clawActionButton)
                }
                .buttonStyle(.bordered)
                .disabled(!actionPolicy.isEnabled(.uninstall))
            }

            if actionAvailability.showsRetryInstall {
                Button {
                    Task { await viewModel.installClaw(); onInstallStateChanged?() }
                } label: {
                    Text("claw.detail.button.retryInstall")
                        .font(MacTypography.Fonts.clawActionButton)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!actionPolicy.isEnabled(.retryInstall))
            }
        }
    }

    /// Reason-coded notice shown in place of the state banner + actions when
    /// the backend reports the claw is not installable. Copy is keyed off the
    /// machine-readable `reasonCode`; the backend `message` appears only as an
    /// optional secondary detail, never as the primary line.
    @ViewBuilder
    private func unavailableNotice(code: ClawUnavailableReasonCode, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "nosign").foregroundColor(MacClawStoreTheme.accentAmber)
                Text(Self.unavailableTitle(for: code))
                    .font(MacTypography.Fonts.clawDetailBanner)
                    .foregroundColor(MacClawStoreTheme.textPrimary)
            }
            if let message, !message.isEmpty {
                Text(verbatim: message)
                    .font(MacTypography.Fonts.clawDetailMeta)
                    .foregroundColor(MacClawStoreTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacClawStoreTheme.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MacClawStoreTheme.accentAmber, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Localized, reason-coded copy. Unknown / future codes fall back to a
    /// generic line so a newer backend never leaks a raw enum name to the UI.
    static func unavailableTitle(for code: ClawUnavailableReasonCode) -> LocalizedStringResource {
        switch code {
        case .catalogOnly:
            return LocalizedStringResource(
                "claw.detail.unavailable.catalogOnly",
                defaultValue: "Not available to install yet",
                comment: "Shown when a claw exists in the catalog for discovery only and cannot be installed."
            )
        case .detectedUnverified:
            return LocalizedStringResource(
                "claw.detail.unavailable.detectedUnverified",
                defaultValue: "This Claw is still being verified",
                comment: "Shown when a claw has been detected but not yet verified for install."
            )
        case .noInstallPlan:
            return LocalizedStringResource(
                "claw.detail.unavailable.noInstallPlan",
                defaultValue: "Install plan unavailable",
                comment: "Shown when a claw qualifies by tier but has no install path (manifest inconsistency)."
            )
        case .unknown:
            return LocalizedStringResource(
                "claw.detail.unavailable.generic",
                defaultValue: "Not available to install",
                comment: "Generic fallback shown when a claw is not installable for an unrecognized reason."
            )
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("claw.detail.section.details")
                .font(MacTypography.Fonts.clawDetailSection)
                .foregroundColor(MacClawStoreTheme.textMuted)
            detailRow(label: "claw.detail.label.language", value: viewModel.claw.language)
            detailRow(label: "claw.detail.label.minRam", value: viewModel.claw.displayMinRAM)
            detailRow(label: "claw.detail.label.binarySize", value: viewModel.claw.displayBinarySize)
            detailRow(label: "claw.detail.label.license", value: viewModel.claw.displayLicense)
            detailRow(label: "claw.detail.label.updatedAt", value: viewModel.claw.displayUpdatedAt)
            detailRow(
                label: "claw.detail.label.installedOn",
                value: String(
                    localized: "claw.detail.value.installedOnCount",
                    defaultValue: "\(viewModel.installedServerCount) of \(viewModel.totalServerCount) paired servers",
                    comment: "Row showing how many paired servers have this claw installed. %1$lld = count installed, %2$lld = total paired servers."
                )
            )
        }
        .padding(12)
        .background(MacClawStoreTheme.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MacClawStoreTheme.bgCardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .font(MacTypography.Fonts.clawDetailMeta)
                .foregroundColor(MacClawStoreTheme.textMuted)
            Spacer()
            Text(value)
                .font(MacTypography.Fonts.clawDetailMeta)
                .foregroundColor(MacClawStoreTheme.textPrimary)
        }
    }
}

private struct StateBanner: View {
    let color: Color
    let icon: String
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(title)
                .font(MacTypography.Fonts.clawDetailBanner)
                .foregroundColor(MacClawStoreTheme.textPrimary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacClawStoreTheme.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
