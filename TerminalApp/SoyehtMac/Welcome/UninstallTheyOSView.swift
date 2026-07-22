import AppKit
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
    let context: SoyehtUninstallPresentationContext

    init(
        onCompleted: @escaping () -> Void,
        compact: Bool = false,
        context: SoyehtUninstallPresentationContext = .inApp
    ) {
        self.onCompleted = onCompleted
        self.compact = compact
        self.context = context
        let defaults: SoyehtUninstallOptions = context == .companion ? .companionDefault : .inAppDefault
        _removeApplicationBundle = State(initialValue: defaults.removeApplicationBundle)
        _removeEngine = State(initialValue: defaults.removeEngine)
        _removeUserData = State(initialValue: defaults.removeUserData)
        _removeCachesAndLogs = State(initialValue: defaults.removeCachesAndLogs)
        _removeMCPConfigs = State(initialValue: defaults.removeMCPConfigs)
        _removeKeychainAndIdentity = State(initialValue: defaults.removeKeychainAndIdentity)
        _leaveHousehold = State(initialValue: defaults.leaveHousehold)
    }

    @StateObject private var uninstaller = TheyOSUninstaller()
    @State private var hasStarted = false
    @State private var failureMessage: String?
    @State private var canForceLocalUninstall = false
    @State private var removeApplicationBundle: Bool
    @State private var removeEngine: Bool
    @State private var removeUserData: Bool
    @State private var removeCachesAndLogs: Bool
    @State private var removeMCPConfigs: Bool
    @State private var removeKeychainAndIdentity: Bool
    @State private var leaveHousehold: Bool

    var body: some View {
        if compact {
            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(BrandColors.surfaceDeep)
        } else {
            ScrollView {
                content
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(
                minWidth: 840,
                maxWidth: .infinity,
                minHeight: 600,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background(BrandColors.surfaceDeep)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if !hasStarted {
                confirmationPanel
            } else {
                progressPanel
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("welcome.uninstall.header.title")
                .font(MacTypography.Fonts.welcomeFlowTitle(compact: compact))
                .foregroundColor(BrandColors.textPrimary)
            Text("welcome.uninstall.header.description")
                .font(MacTypography.Fonts.welcomeFlowBody(compact: compact))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Confirmation

    private var confirmationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            warningCard
            optionsCard
            startButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("welcome.uninstall.warning.title")
                    .font(MacTypography.Fonts.welcomeSectionLabel)
                    .foregroundColor(BrandColors.textPrimary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(BrandColors.accentAmber)
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("welcome.uninstall.warning.bullet.vms")
                bullet("welcome.uninstall.warning.bullet.data")
                bullet("welcome.uninstall.warning.bullet.servers")
                bullet("welcome.uninstall.warning.bullet.brew")
                if context == .inApp {
                    bullet("welcome.uninstall.warning.bullet.appTrash")
                }
            }
        }
        .padding(12)
        .background(BrandColors.card)
        .overlay(
            RoundedRectangle(cornerRadius: MacSurface.Radius.control)
                .stroke(BrandColors.accentAmberStrong, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(MacTypography.Fonts.welcomeSectionLabel)
                .foregroundColor(BrandColors.textMuted)
            Text(key)
                .font(MacTypography.Fonts.welcomeProgressBody)
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource(
                "welcome.uninstall.options.title",
                defaultValue: "What to remove",
                comment: "Heading above checkboxes in the Soyeht graphical uninstaller."
            ))
            .font(MacTypography.Fonts.welcomeSectionLabel)
            .foregroundColor(BrandColors.textPrimary)

            optionToggle(
                title: LocalizedStringResource(
                    "welcome.uninstall.option.removeApp",
                    defaultValue: "Soyeht app",
                    comment: "Checkbox label for removing Soyeht.app."
                ),
                detail: context == .inApp
                    ? LocalizedStringResource(
                        "welcome.uninstall.option.removeApp.inAppDetail",
                        defaultValue: "The running app cannot delete itself. Move Soyeht to the Trash after this finishes.",
                        comment: "Checkbox detail explaining the in-app uninstaller cannot delete the running app bundle."
                    )
                    : LocalizedStringResource(
                        "welcome.uninstall.option.removeApp.companionDetail",
                        defaultValue: "Removes Soyeht.app from Applications.",
                        comment: "Checkbox detail for companion app bundle removal."
                    ),
                isOn: $removeApplicationBundle
            )
            .disabled(context == .inApp)

            optionToggle(
                title: LocalizedStringResource("welcome.uninstall.option.engine", defaultValue: "theyOS engine", comment: "Checkbox label for removing the embedded theyOS engine."),
                detail: LocalizedStringResource("welcome.uninstall.option.engineDetail", defaultValue: "Stops and unregisters the background service before removing its files.", comment: "Checkbox detail for engine removal."),
                isOn: $removeEngine
            )
            optionToggle(
                title: LocalizedStringResource("welcome.uninstall.option.userData", defaultValue: "Local data", comment: "Checkbox label for removing local Soyeht data."),
                detail: LocalizedStringResource("welcome.uninstall.option.userDataDetail", defaultValue: "Removes local VMs, snapshots, conversations, and household state.", comment: "Checkbox detail for local data removal."),
                isOn: $removeUserData
            )
            optionToggle(
                title: LocalizedStringResource("welcome.uninstall.option.caches", defaultValue: "Caches and logs", comment: "Checkbox label for removing caches and logs."),
                detail: LocalizedStringResource("welcome.uninstall.option.cachesDetail", defaultValue: "Removes caches, preferences, diagnostic reports, and runtime logs.", comment: "Checkbox detail for caches/logs removal."),
                isOn: $removeCachesAndLogs
            )
            optionToggle(
                title: LocalizedStringResource("welcome.uninstall.option.mcp", defaultValue: "Agent integrations", comment: "Checkbox label for removing MCP integrations."),
                detail: LocalizedStringResource("welcome.uninstall.option.mcpDetail", defaultValue: "Removes Soyeht MCP entries from local agent configuration files.", comment: "Checkbox detail for MCP cleanup."),
                isOn: $removeMCPConfigs
            )
            optionToggle(
                title: LocalizedStringResource("welcome.uninstall.option.identity", defaultValue: "Keychain and local identity", comment: "Checkbox label for keychain and identity cleanup."),
                detail: LocalizedStringResource("welcome.uninstall.option.identityDetail", defaultValue: "Removes Soyeht tokens, pairing secrets, and local signing keys.", comment: "Checkbox detail for keychain cleanup."),
                isOn: $removeKeychainAndIdentity
            )
            optionToggle(
                title: LocalizedStringResource("welcome.uninstall.option.leaveHousehold", defaultValue: "Leave household before removing identity", comment: "Checkbox label for household revocation before uninstall."),
                detail: LocalizedStringResource("welcome.uninstall.option.leaveHouseholdDetail", defaultValue: "Publishes revocation before deleting this Mac's local key. If offline, you can force local removal after Soyeht explains the tradeoff.", comment: "Checkbox detail for household revocation."),
                isOn: $leaveHousehold
            )
            .disabled(!removeKeychainAndIdentity)
        }
        .padding(12)
        .background(BrandColors.card)
        .overlay(
            RoundedRectangle(cornerRadius: MacSurface.Radius.control)
                .stroke(BrandColors.border, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionToggle(
        title: LocalizedStringResource,
        detail: LocalizedStringResource,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(CheckboxToggleStyle())
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MacTypography.Fonts.welcomeProgressTitle)
                    .foregroundColor(BrandColors.textPrimary)
                Text(detail)
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(MacTypography.Fonts.welcomeProgressTitle)
                    .foregroundColor(BrandColors.textPrimary)
                Spacer()
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("welcome.uninstall.button.retry", action: retry)
                        .buttonStyle(.bordered)
                    if canForceLocalUninstall {
                        Button(action: forceLocalUninstall) {
                            Text(LocalizedStringResource(
                                "welcome.uninstall.button.forceLocal",
                                defaultValue: "Force Local Uninstall",
                                comment: "Button that continues uninstall without household revocation after the user saw the tradeoff."
                            ))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BrandColors.accentAmber)
                    }
                }
            }

            if let hint = uninstaller.residualHint {
                Text(hint)
                    .font(MacTypography.Fonts.welcomeHintMono)
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(BrandColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
            }

            if case .done = uninstaller.phase {
                VStack(alignment: .leading, spacing: 10) {
                    if context == .inApp {
                        Text(LocalizedStringResource(
                            "welcome.uninstall.done.moveToTrash",
                            defaultValue: "Soyeht was removed from this Mac. Move Soyeht to the Trash to finish removing the running app.",
                            comment: "Final in-app uninstaller note explaining the running app bundle cannot delete itself."
                        ))
                        .font(MacTypography.Fonts.welcomeProgressBody)
                        .foregroundColor(BrandColors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button("welcome.uninstall.button.dismiss", action: onCompleted)
                            .buttonStyle(.borderedProminent)
                        if let logURL = uninstaller.logURL {
                            Button(action: { reveal(logURL) }) {
                                Text(LocalizedStringResource(
                                    "welcome.uninstall.button.revealLog",
                                    defaultValue: "Reveal Log",
                                    comment: "Button that reveals the preserved uninstall log in Finder."
                                ))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            logTail
        }
    }

    private var phaseDot: some View {
        let color: Color = {
            if case .failed = uninstaller.phase { return BrandColors.accentAmber }
            if case .done = uninstaller.phase { return BrandColors.accentGreen }
            return BrandColors.accentAmberStrong
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var logTail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(uninstaller.log.suffix(20).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(MacTypography.Fonts.welcomeLog)
                        .foregroundColor(BrandColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 160)
        .background(BrandColors.card)
        .overlay(
            RoundedRectangle(cornerRadius: MacSurface.Radius.control).stroke(BrandColors.border, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.control))
    }

    // MARK: - Actions

    private func beginUninstall() {
        hasStarted = true
        failureMessage = nil
        canForceLocalUninstall = false
        Task { await runFullFlow(forceLocalOnly: false) }
    }

    private func retry() {
        failureMessage = nil
        canForceLocalUninstall = false
        Task { await runFullFlow(forceLocalOnly: false) }
    }

    private func forceLocalUninstall() {
        failureMessage = nil
        canForceLocalUninstall = false
        Task { await runFullFlow(forceLocalOnly: true) }
    }

    private func runFullFlow(forceLocalOnly: Bool) async {
        do {
            try await uninstaller.uninstall(options: currentOptions(forceLocalOnly: forceLocalOnly))
        } catch {
            failureMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let uninstallError = error as? TheyOSUninstallerError,
               case .householdRevocationFailed = uninstallError {
                canForceLocalUninstall = true
            }
        }
    }

    private func currentOptions(forceLocalOnly: Bool) -> SoyehtUninstallOptions {
        SoyehtUninstallOptions(
            removeApplicationBundle: removeApplicationBundle,
            removeEngine: removeEngine,
            removeUserData: removeUserData,
            removeCachesAndLogs: removeCachesAndLogs,
            removeMCPConfigs: removeMCPConfigs,
            removeKeychainAndIdentity: removeKeychainAndIdentity,
            leaveHousehold: leaveHousehold && removeKeychainAndIdentity,
            forceLocalOnly: forceLocalOnly
        )
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
