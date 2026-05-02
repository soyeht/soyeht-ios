import SwiftUI
import SoyehtCore

// MARK: - Claw Setup View (Deploy Configuration)

struct ClawSetupView: View {
    @StateObject private var viewModel: ClawSetupViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeployConfirmation = false

    init(claw: Claw) {
        _viewModel = StateObject(wrappedValue: ClawSetupViewModel(claw: claw))
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Nav header
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Text(verbatim: "<")
                                .font(Typography.monoPageTitle)
                                .foregroundColor(SoyehtTheme.accentGreen)
                        }
                        Text("clawSetup.title")
                            .font(Typography.monoPageTitle)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }

                    // Selected Claw
                    sectionLabel("clawSetup.section.selectedClaw")
                    selectedClawCard

                    // Configuration
                    sectionLabel("clawSetup.section.configuration")
                    serverSelector
                    serverTypeSelector
                    nameInput
                    resourceCards

                    // Assignment
                    sectionLabel("clawSetup.section.assignment")
                    assignmentSelector
                    privacyNotice

                    // Access
                    sectionLabel("clawSetup.section.access")
                    accessCheckmarks

                    // Deploy Button
                    deployButton

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(Typography.monoSmall)
                            .foregroundColor(SoyehtTheme.textWarning)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }

                    // Footer
                    Text(LocalizedStringResource(
                        "clawSetup.footer.serversAvailable",
                        defaultValue: "\(viewModel.servers.count) server(s) available",
                        comment: "Footer — how many paired servers are available. %lld = count."
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
        .task {
            await viewModel.loadOptions()
        }
        .onChange(of: viewModel.deploySucceeded) { succeeded in
            if succeeded { dismiss() }
        }
        .sheet(isPresented: $showDeployConfirmation) {
            DeployConfirmSheet(
                clawName: viewModel.claw.name,
                clawType: viewModel.claw.language,
                cpuCores: viewModel.cpuCores,
                ramMB: viewModel.ramMB,
                diskGB: viewModel.diskGB,
                showsDisk: viewModel.showsDiskControl,
                serverType: viewModel.serverType,
                serverName: viewModel.selectedServer?.name ?? "server",
                onConfirm: {
                    showDeployConfirmation = false
                    Task { await viewModel.deploy() }
                },
                onCancel: { showDeployConfirmation = false }
            )
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Selected Claw Card

    private var selectedClawCard: some View {
        let info = ClawMockData.storeInfo(for: viewModel.claw.name)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(viewModel.claw.name)
                        .font(Typography.monoSection)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(viewModel.claw.language.capitalized)
                        .font(Typography.monoMicroBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoyehtTheme.historyGreenBg)
                }
                Text(viewModel.claw.description)
                    .font(Typography.monoLabelRegular)
                    .foregroundColor(SoyehtTheme.textComment)
                Text(verbatim: "\(info.ratingStars) \(String(format: "%.1f", info.rating)) \u{00B7} \(info.installCount) installs")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.historyGreen)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(Typography.iconStatus)
                .foregroundColor(SoyehtTheme.historyGreen)
        }
        .padding(16)
        .background(Color(hex: "#0A0A0A"))
        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
    }

    // MARK: - Server Selector

    private var serverSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("clawSetup.field.server")
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            Menu {
                ForEach(Array(viewModel.servers.enumerated()), id: \.element.id) { index, server in
                    Button("\(server.name) \u{00B7} \(server.host.components(separatedBy: ":").first ?? server.host)") {
                        viewModel.selectedServerIndex = index
                    }
                }
            } label: {
                HStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(SoyehtTheme.historyGreen)
                            .frame(width: 6, height: 6)
                            .shadow(color: SoyehtTheme.historyGreen.opacity(0.6), radius: 6)
                        Text(viewModel.selectedServer?.name ?? String(localized: "clawSetup.field.server.placeholder", comment: "Menu placeholder when no server is selected yet."))
                            .font(Typography.monoBody)
                            .foregroundColor(SoyehtTheme.textPrimary)
                        if let server = viewModel.selectedServer {
                            Text("\u{00B7} \(server.host.components(separatedBy: ":").first ?? server.host)")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textComment)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(Typography.monoLabelRegular)
                        .foregroundColor(SoyehtTheme.textComment)
                }
                .padding(16)
                .background(SoyehtTheme.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Server Type Selector

    private var serverTypeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("clawSetup.field.serverType")
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            HStack(spacing: 10) {
                Button { viewModel.serverType = "linux" } label: {
                    serverTypeButton(label: "linux", icon: "terminal", selected: viewModel.serverType == "linux")
                }
                .buttonStyle(.plain)
                Button { viewModel.serverType = "macos" } label: {
                    serverTypeButton(label: "mac", icon: "laptopcomputer", selected: viewModel.serverType == "macos")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func serverTypeButton(label: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Typography.monoBody)
                .foregroundColor(selected ? SoyehtTheme.historyGreen : SoyehtTheme.textComment)
            Text(label)
                .font(selected ? Typography.monoCardTitle : Typography.monoCardBody)
                .foregroundColor(selected ? SoyehtTheme.historyGreen : SoyehtTheme.textComment)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(SoyehtTheme.bgPrimary)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? SoyehtTheme.historyGreen : SoyehtTheme.bgCardBorder, lineWidth: 1)
        )
    }

    // MARK: - Name Input

    private var nameInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("clawSetup.field.clawName")
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            TextField("", text: $viewModel.clawName)
                .font(Typography.monoBody)
                .foregroundColor(SoyehtTheme.textPrimary)
                .padding(16)
                .background(SoyehtTheme.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if let error = viewModel.nameValidationError {
                Text(error)
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.accentAmber)
            }
        }
    }

    // MARK: - Resources

    private var resourceCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("clawSetup.field.resources")
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            if let warning = viewModel.resourceOptionsWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.accentAmber)
                    Text(warning)
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.accentAmber)
                }
            }

            HStack(spacing: 10) {
                resourceCard(
                    icon: "cpu",
                    label: String(
                        localized: "clawSetup.resource.cores",
                        defaultValue: "\(viewModel.cpuCores) cores",
                        comment: "CPU cores label. %lld = count."
                    ),
                    canDecrement: viewModel.canDecrementCPU,
                    canIncrement: viewModel.canIncrementCPU,
                    onIncrement: viewModel.incrementCPU,
                    onDecrement: viewModel.decrementCPU
                )
                resourceCard(
                    icon: "memorychip",
                    label: formatRAM(viewModel.ramMB),
                    canDecrement: viewModel.canDecrementRAM,
                    canIncrement: viewModel.canIncrementRAM,
                    onIncrement: viewModel.incrementRAM,
                    onDecrement: viewModel.decrementRAM
                )
                if viewModel.showsDiskControl {
                    resourceCard(
                        icon: "internaldrive",
                        label: String(
                            localized: "clawSetup.resource.diskGB",
                            defaultValue: "\(viewModel.diskGB) GB",
                            comment: "Disk size label. %lld = gigabytes."
                        ),
                        canDecrement: viewModel.canDecrementDisk,
                        canIncrement: viewModel.canIncrementDisk,
                        onIncrement: viewModel.incrementDisk,
                        onDecrement: viewModel.decrementDisk
                    )
                }
            }
        }
    }

    private func resourceCard(icon: String, label: String, canDecrement: Bool, canIncrement: Bool, onIncrement: @escaping () -> Void, onDecrement: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(Typography.monoBody)
                .foregroundColor(SoyehtTheme.historyGreen)
            Text(label)
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.textPrimary)
            HStack(spacing: 0) {
                Button(action: onDecrement) {
                    Text("\u{2212}")  // i18n-exempt: U+2212 mathematical minus glyph
                        .font(Typography.monoSection)
                        .foregroundColor(canDecrement ? SoyehtTheme.textComment : SoyehtTheme.textComment.opacity(0.2))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canDecrement)
                Button(action: onIncrement) {
                    Text("+")
                        .font(Typography.monoSection)
                        .foregroundColor(canIncrement ? SoyehtTheme.historyGreen : SoyehtTheme.historyGreen.opacity(0.2))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canIncrement)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(SoyehtTheme.bgPrimary)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
        )
    }

    private func formatRAM(_ mb: Int) -> String {
        mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    // MARK: - Assignment

    private var assignmentSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("clawSetup.field.assignTo")
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            Menu {
                Button("clawSetup.assignment.unassigned") { viewModel.assignmentTarget = .admin }
                ForEach(viewModel.users) { user in
                    Button("\(user.username) (\(user.role))") {
                        viewModel.assignmentTarget = .existingUser(user)
                    }
                }
                Button("clawSetup.assignment.inviteNew") { }
                    .disabled(true)
            } label: {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "person")
                            .font(Typography.monoBody)
                            .foregroundColor(SoyehtTheme.textComment)
                        Text(assignmentLabel)
                            .font(Typography.monoBody)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(Typography.monoLabelRegular)
                        .foregroundColor(SoyehtTheme.textComment)
                }
                .padding(16)
                .background(SoyehtTheme.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
            }
        }
    }

    private var assignmentLabel: String {
        switch viewModel.assignmentTarget {
        case .admin: return String(localized: "clawSetup.assignment.unassigned", comment: "Assignment target label — admin-only (no user assigned yet).")
        case .existingUser(let user): return user.username
        }
    }

    // MARK: - Privacy Notice

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.textComment)
            Text("clawSetup.privacyNotice")
                .font(Typography.monoTag)
                .italic()
                .foregroundColor(SoyehtTheme.textComment)
        }
        .padding(14)
        .background(Color(hex: "#0A0A0A"))
        .overlay(
            HStack {
                Rectangle()
                    .fill(SoyehtTheme.historyGreen)
                    .frame(width: 3)
                Spacer()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Access

    private var accessCheckmarks: some View {
        VStack(alignment: .leading, spacing: 10) {
            accessRow(label: "clawSetup.access.ssh")
            accessRow(label: "clawSetup.access.web")
        }
    }

    private func accessRow(label: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.historyGreen)
            Text(label)
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textPrimary)
        }
    }

    // MARK: - Deploy Button

    private var deployButton: some View {
        Button(action: { showDeployConfirmation = true }) {
            Group {
                if viewModel.isDeploying {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(SoyehtTheme.historyGreen)
                            .scaleEffect(0.9)
                        Text("clawSetup.deployingStatus")
                            .font(Typography.monoBodyBold)
                            .foregroundColor(SoyehtTheme.historyGreen)
                    }
                } else {
                    Text("clawSetup.button.deployClaw")
                        .font(Typography.monoBodyBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(viewModel.canDeploy || viewModel.isDeploying ? 1.0 : 0.4)
        .disabled(!viewModel.canDeploy)
    }

    // MARK: - Helpers

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(Typography.monoBody)
            .foregroundColor(SoyehtTheme.textComment)
    }
}

// MARK: - Deploy Confirm Sheet

/// Bottom sheet replacement for `.confirmationDialog`. The native dialog
/// renders as a centered gray alert on iOS 26 which destroys the terminal
/// aesthetic. This sheet matches the rest of the app: monospaced, dark,
/// accent-green primary, red cancel, with a clear summary of what will be
/// created.
private struct DeployConfirmSheet: View {
    let clawName: String
    let clawType: String
    let cpuCores: Int
    let ramMB: Int
    let diskGB: Int
    let showsDisk: Bool
    let serverType: String
    let serverName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var ramLabel: String {
        ramMB >= 1024 ? "\(ramMB / 1024) GB" : "\(ramMB) MB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text(verbatim: ">")
                    .font(Typography.monoSection)
                    .foregroundColor(SoyehtTheme.historyGreen)
                Text("deployConfirm.title")
                    .font(Typography.monoSection)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)

            // Claw summary card
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(clawName)
                        .font(Typography.monoNavTitleBold)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(clawType.capitalized)
                        .font(Typography.monoSmallBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoyehtTheme.historyGreenBg)
                    Spacer()
                }
                Text(LocalizedStringResource(
                    "deployConfirm.onServer",
                    defaultValue: "on \(serverName) · \(serverType)",
                    comment: "Summary line. %1$@ = server name, %2$@ = 'linux'/'macos' raw identifier."
                ))
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Specs list
            VStack(alignment: .leading, spacing: 8) {
                specLine(icon: "cpu", value: String(
                    localized: "clawSetup.resource.cores",
                    defaultValue: "\(cpuCores) cores",
                    comment: "CPU cores label. %lld = count."
                ))
                specLine(icon: "memorychip", value: String(
                    localized: "deployConfirm.spec.ram",
                    defaultValue: "\(ramLabel) RAM",
                    comment: "RAM spec line. %@ = preformatted RAM amount (e.g. '2 GB' or '512 MB')."
                ))
                if showsDisk {
                    specLine(icon: "internaldrive", value: String(
                        localized: "deployConfirm.spec.disk",
                        defaultValue: "\(diskGB) GB disk",
                        comment: "Disk spec line. %lld = gigabytes."
                    ))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "#0E0E0E"))
            .overlay(
                Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            // Buttons
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("common.button.cancel.lower")
                        .font(Typography.monoBodyLargeSemi)
                        .foregroundColor(SoyehtTheme.accentRed)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(SoyehtTheme.accentRed.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("soyeht.deployConfirm.cancel")

                Button(action: onConfirm) {
                    Text("deployConfirm.title")
                        .font(Typography.monoBodyLargeBold)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(SoyehtTheme.historyGreen)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("soyeht.deployConfirm.deploy")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SoyehtTheme.bgPrimary)
    }

    private func specLine(icon: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(Typography.sansCard)
                .foregroundColor(SoyehtTheme.historyGreen)
                .frame(width: 18)
            Text(value)
                .font(Typography.monoBody)
                .foregroundColor(SoyehtTheme.textPrimary)
            Spacer()
        }
    }
}
