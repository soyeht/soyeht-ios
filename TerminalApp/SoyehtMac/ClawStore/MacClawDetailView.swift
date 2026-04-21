import SwiftUI
import SoyehtCore

/// Detail view for a single Claw. Shows the catalog metadata (description,
/// language, minimum RAM, license, version), the current install state,
/// and the relevant lifecycle action (install / retry / uninstall /
/// deploy). Deploy opens `MacClawSetupView` via the shared NavigationStack.
struct MacClawDetailView: View {
    let context: ServerContext
    /// Called after any install/uninstall action so the parent store view model
    /// can reload and begin its own window-lifetime polling (surviving back-nav).
    var onInstallStateChanged: (() -> Void)?
    @StateObject private var viewModel: ClawDetailViewModel

    init(claw: Claw, context: ServerContext, onInstallStateChanged: (() -> Void)? = nil) {
        self.context = context
        self.onInstallStateChanged = onInstallStateChanged
        _viewModel = StateObject(wrappedValue: ClawDetailViewModel(claw: claw, context: context))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                stateBanner
                actions
                details
                if viewModel.isPolling {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("claw.detail.status.polling")
                            .font(.system(size: 10))
                            .foregroundColor(MacClawStoreTheme.textMuted)
                    }
                }
                if let actionError = viewModel.actionError {
                    Text(actionError)
                        .font(.system(size: 11))
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
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(MacClawStoreTheme.textPrimary)
                Text(verbatim: "v\(viewModel.claw.displayVersion)")
                    .font(.system(size: 14))
                    .foregroundColor(MacClawStoreTheme.textMuted)
            }
            Text(viewModel.claw.description)
                .font(.system(size: 13))
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
                        .font(.system(size: 11))
                        .foregroundColor(MacClawStoreTheme.textSecondary)
                }
            }
        case .installing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                StateBanner(color: MacClawStoreTheme.statusGreen, icon: "arrow.down.circle", title: "claw.detail.banner.installing")
                if let p = progress {
                    ProgressView(value: p.fraction).tint(MacClawStoreTheme.statusGreen)
                    Text(verbatim: "\(p.phase.rawValue) · \(p.percent)%")
                        .font(.system(size: 11))
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
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(MacClawStoreTheme.textMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .font(.system(size: 11))
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
        HStack(spacing: 8) {
            switch viewModel.claw.installState {
            case .notInstalled:
                Button("claw.detail.button.install") {
                    Task { await viewModel.installClaw(); onInstallStateChanged?() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isPerformingAction)
            case .installed:
                NavigationLink(value: ClawRoute.setup(viewModel.claw)) {
                    Text("claw.detail.button.createInstance")
                }
                .buttonStyle(.borderedProminent)
                Button("claw.detail.button.uninstall") {
                    Task { await viewModel.uninstallClaw(); onInstallStateChanged?() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isPerformingAction)
            case .installedButBlocked:
                Button("claw.detail.button.uninstall") {
                    Task { await viewModel.uninstallClaw(); onInstallStateChanged?() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isPerformingAction)
            case .installFailed:
                Button("claw.detail.button.retryInstall") {
                    Task { await viewModel.installClaw(); onInstallStateChanged?() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isPerformingAction)
            case .installing, .uninstalling, .unknown:
                EmptyView()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("claw.detail.section.details")
                .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 11))
                .foregroundColor(MacClawStoreTheme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 11))
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(MacClawStoreTheme.textPrimary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
