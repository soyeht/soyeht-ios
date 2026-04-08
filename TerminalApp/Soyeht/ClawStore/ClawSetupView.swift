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
        .confirmationDialog("deploy \(viewModel.claw.name)?", isPresented: $showDeployConfirmation, titleVisibility: .visible) {
            Button("deploy") { Task { await viewModel.deploy() } }
            Button("cancel", role: .cancel) { }
        } message: {
            Text(viewModel.serverType == "macos"
                ? "\(viewModel.cpuCores) cores \u{00B7} \(formatRAM(viewModel.ramMB)) RAM\non \(viewModel.selectedServer?.name ?? "server")"
                : "\(viewModel.cpuCores) cores \u{00B7} \(formatRAM(viewModel.ramMB)) RAM \u{00B7} \(viewModel.diskGB) GB disk\non \(viewModel.selectedServer?.name ?? "server")")
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
                    canDecrement: viewModel.cpuCores > (viewModel.resourceOptions?.cpuCores.min ?? 1),
                    canIncrement: viewModel.cpuCores < (viewModel.resourceOptions?.cpuCores.max ?? 4),
                    onIncrement: {
                        let max = viewModel.resourceOptions?.cpuCores.max ?? 4
                        if viewModel.cpuCores < max { viewModel.cpuCores += 1 }
                    },
                    onDecrement: {
                        let min = viewModel.resourceOptions?.cpuCores.min ?? 1
                        if viewModel.cpuCores > min { viewModel.cpuCores -= 1 }
                    }
                )
                resourceCard(
                    icon: "memorychip",
                    label: formatRAM(viewModel.ramMB),
                    canDecrement: {
                        let min = viewModel.resourceOptions?.ramMb.min ?? 512
                        let step = viewModel.ramMB > 4096 ? 2048 : 1024
                        return viewModel.ramMB - step >= min
                    }(),
                    canIncrement: {
                        let max = viewModel.resourceOptions?.ramMb.max ?? 8192
                        let step = viewModel.ramMB >= 4096 ? 2048 : 1024
                        return viewModel.ramMB + step <= max
                    }(),
                    onIncrement: {
                        let max = viewModel.resourceOptions?.ramMb.max ?? 8192
                        let step = viewModel.ramMB >= 4096 ? 2048 : 1024
                        if viewModel.ramMB + step <= max { viewModel.ramMB += step }
                    },
                    onDecrement: {
                        let min = viewModel.resourceOptions?.ramMb.min ?? 512
                        let step = viewModel.ramMB > 4096 ? 2048 : 1024
                        if viewModel.ramMB - step >= min { viewModel.ramMB -= step }
                    }
                )
                if viewModel.serverType != "macos" {
                    resourceCard(
                        icon: "internaldrive",
                        label: "\(viewModel.diskGB) GB",
                        canDecrement: viewModel.diskGB - 5 >= (viewModel.resourceOptions?.diskGb.min ?? 5),
                        canIncrement: viewModel.diskGB + 5 <= (viewModel.resourceOptions?.diskGb.max ?? 50),
                        onIncrement: {
                            let max = viewModel.resourceOptions?.diskGb.max ?? 50
                            if viewModel.diskGB + 5 <= max { viewModel.diskGB += 5 }
                        },
                        onDecrement: {
                            let min = viewModel.resourceOptions?.diskGb.min ?? 5
                            if viewModel.diskGB - 5 >= min { viewModel.diskGB -= 5 }
                        }
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
                Button(action: onIncrement) {
                    Text("+")
                        .font(SoyehtTheme.sectionTitle)
                        .foregroundColor(canIncrement ? SoyehtTheme.historyGreen : SoyehtTheme.historyGreen.opacity(0.2))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
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
            Text("deploy claw")
                .font(SoyehtTheme.bodyBold)
                .foregroundColor(SoyehtTheme.historyGreen)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .opacity(viewModel.canDeploy ? 1.0 : 0.4)
        .disabled(!viewModel.canDeploy)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(SoyehtTheme.bodyMono)
            .foregroundColor(SoyehtTheme.textComment)
    }
}
