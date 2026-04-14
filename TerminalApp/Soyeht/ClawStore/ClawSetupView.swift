import SwiftUI

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
                            Text("<")
                                .font(SoyehtTheme.heading)
                                .foregroundColor(SoyehtTheme.historyGreen)
                        }
                        Text("claw setup")
                            .font(SoyehtTheme.navTitle)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }

                    // Selected Claw
                    sectionLabel("// selected claw")
                    selectedClawCard

                    // Configuration
                    sectionLabel("// configuration")
                    serverSelector
                    serverTypeSelector
                    nameInput
                    resourceCards

                    // Assignment
                    sectionLabel("// assignment")
                    assignmentSelector
                    privacyNotice

                    // Access
                    sectionLabel("// access")
                    accessCheckmarks

                    // Deploy Button
                    deployButton

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(SoyehtTheme.smallMono)
                            .foregroundColor(SoyehtTheme.textWarning)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }

                    // Footer
                    Text("\(viewModel.servers.count) server(s) available")
                        .font(SoyehtTheme.tagFont)
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
                        .font(SoyehtTheme.sectionTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(viewModel.claw.language.capitalized)
                        .font(SoyehtTheme.microBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoyehtTheme.historyGreenBg)
                }
                Text(viewModel.claw.description)
                    .font(SoyehtTheme.labelRegular)
                    .foregroundColor(SoyehtTheme.textComment)
                Text("\(info.ratingStars) \(String(format: "%.1f", info.rating)) \u{00B7} \(info.installCount) installs")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.historyGreen)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(SoyehtTheme.historyGreen)
        }
        .padding(16)
        .background(Color(hex: "#0A0A0A"))
        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
    }

    // MARK: - Server Selector

    private var serverSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("server")
                .font(SoyehtTheme.labelRegular)
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
                        Text(viewModel.selectedServer?.name ?? "select server")
                            .font(SoyehtTheme.bodyMono)
                            .foregroundColor(SoyehtTheme.textPrimary)
                        if let server = viewModel.selectedServer {
                            Text("\u{00B7} \(server.host.components(separatedBy: ":").first ?? server.host)")
                                .font(SoyehtTheme.tagFont)
                                .foregroundColor(SoyehtTheme.textComment)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(SoyehtTheme.labelRegular)
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
            Text("server type")
                .font(SoyehtTheme.labelRegular)
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
                .font(SoyehtTheme.bodyMono)
                .foregroundColor(selected ? SoyehtTheme.historyGreen : SoyehtTheme.textComment)
            Text(label)
                .font(selected ? SoyehtTheme.cardTitle : SoyehtTheme.cardBody)
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
            Text("claw name")
                .font(SoyehtTheme.labelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            TextField("", text: $viewModel.clawName)
                .font(SoyehtTheme.bodyMono)
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
                    .font(SoyehtTheme.tagFont)
                    .foregroundColor(SoyehtTheme.accentAmber)
            }
        }
    }

    // MARK: - Resources

    private var resourceCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("resources")
                .font(SoyehtTheme.labelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            if let warning = viewModel.resourceOptionsWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(SoyehtTheme.tagFont)
                        .foregroundColor(SoyehtTheme.accentAmber)
                    Text(warning)
                        .font(SoyehtTheme.tagFont)
                        .foregroundColor(SoyehtTheme.accentAmber)
                }
            }

            HStack(spacing: 10) {
                resourceCard(
                    icon: "cpu",
                    label: "\(viewModel.cpuCores) cores",
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
                        label: "\(viewModel.diskGB) GB",
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
                .font(SoyehtTheme.bodyMono)
                .foregroundColor(SoyehtTheme.historyGreen)
            Text(label)
                .font(SoyehtTheme.labelRegular)
                .foregroundColor(SoyehtTheme.textPrimary)
            HStack(spacing: 0) {
                Button(action: onDecrement) {
                    Text("\u{2212}")
                        .font(SoyehtTheme.sectionTitle)
                        .foregroundColor(canDecrement ? SoyehtTheme.textComment : SoyehtTheme.textComment.opacity(0.2))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canDecrement)
                Button(action: onIncrement) {
                    Text("+")
                        .font(SoyehtTheme.sectionTitle)
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
            Text("assign to")
                .font(SoyehtTheme.labelRegular)
                .foregroundColor(SoyehtTheme.textComment)

            Menu {
                Button("unassigned (admin only)") { viewModel.assignmentTarget = .admin }
                ForEach(viewModel.users) { user in
                    Button("\(user.username) (\(user.role))") {
                        viewModel.assignmentTarget = .existingUser(user)
                    }
                }
                Button("invite new user... (coming soon)") { }
                    .disabled(true)
            } label: {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "person")
                            .font(SoyehtTheme.bodyMono)
                            .foregroundColor(SoyehtTheme.textComment)
                        Text(assignmentLabel)
                            .font(SoyehtTheme.bodyMono)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(SoyehtTheme.labelRegular)
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
        case .admin: return "unassigned (admin only)"
        case .existingUser(let user): return user.username
        }
    }

    // MARK: - Privacy Notice

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .font(SoyehtTheme.labelRegular)
                .foregroundColor(SoyehtTheme.textComment)
            Text("once assigned, you will not have access to this user's data")
                .font(SoyehtTheme.tagFont)
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
            accessRow(label: "terminal SSH access")
            accessRow(label: "web browser access")
        }
    }

    private func accessRow(label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(SoyehtTheme.labelFont)
                .foregroundColor(SoyehtTheme.historyGreen)
            Text(label)
                .font(SoyehtTheme.tagFont)
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
                        Text("deploying...")
                            .font(SoyehtTheme.bodyBold)
                            .foregroundColor(SoyehtTheme.historyGreen)
                    }
                } else {
                    Text("deploy claw")
                        .font(SoyehtTheme.bodyBold)
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(SoyehtTheme.bodyMono)
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
                Text(">")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(SoyehtTheme.historyGreen)
                Text("deploy")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(clawType.capitalized)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoyehtTheme.historyGreenBg)
                    Spacer()
                }
                Text("on \(serverName) · \(serverType)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Specs list
            VStack(alignment: .leading, spacing: 8) {
                specLine(icon: "cpu", value: "\(cpuCores) cores")
                specLine(icon: "memorychip", value: "\(ramLabel) RAM")
                if showsDisk {
                    specLine(icon: "internaldrive", value: "\(diskGB) GB disk")
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
                    Text("cancel")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
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
                    Text("deploy")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
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
                .font(.system(size: 13))
                .foregroundColor(SoyehtTheme.historyGreen)
                .frame(width: 18)
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(SoyehtTheme.textPrimary)
            Spacer()
        }
    }
}
