import SwiftUI
import SoyehtCore

/// Setup / deploy form for a single claw. Collects a name, target server
/// (derived from `SessionStore.shared.pairedServers`), and resource
/// overrides. Deploy hands off to `ClawDeployMonitor.shared`, which the
/// iOS AppDelegate wires to ActivityKit; macOS uses the no-op manager
/// injected by default in SoyehtCore.
///
/// This is a pragmatic fork of the iOS `ClawSetupView` — same ViewModel,
/// but without `.presentationDetents()` (iOS 16+ only) and with macOS
/// controls where it matters (toggle for server type, stepper-like inc/
/// dec buttons instead of iOS sliders).
struct MacClawSetupView: View {
    @StateObject private var viewModel: ClawSetupViewModel
    @Environment(\.dismiss) private var dismiss

    init(claw: Claw, serverId: String? = nil) {
        _viewModel = StateObject(wrappedValue: ClawSetupViewModel(claw: claw, initialServerId: serverId))
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(viewModel.claw.name)
                        .font(MacTypography.Fonts.clawSetupTitle)
                    Spacer()
                    Text(verbatim: "v\(viewModel.claw.displayVersion)")
                        .font(MacTypography.Fonts.clawSetupCaption)
                        .foregroundColor(MacClawStoreTheme.textMuted)
                }
                TextField("claw.setup.field.instanceName.placeholder", text: $viewModel.clawName)
                    .font(MacTypography.Fonts.clawSetupBody)
                    .textFieldStyle(.roundedBorder)
                if let error = viewModel.nameValidationError {
                    Text(error)
                        .font(MacTypography.Fonts.clawSetupCaption)
                        .foregroundColor(MacClawStoreTheme.accentAmber)
                }
            } header: {
                Text("claw.setup.section.instance")
                    .font(MacTypography.Fonts.clawSetupSection)
                    .foregroundColor(MacClawStoreTheme.textMuted)
            }

            Section {
                Picker("claw.setup.field.server.label", selection: $viewModel.selectedServerIndex) {
                    ForEach(Array(viewModel.servers.enumerated()), id: \.offset) { idx, server in
                        Text(verbatim: "\(server.name) · \(server.host)").tag(idx)
                    }
                }
                .font(MacTypography.Fonts.clawSetupBody)
                .pickerStyle(.menu)
            } header: {
                Text("claw.setup.section.destination")
                    .font(MacTypography.Fonts.clawSetupSection)
                    .foregroundColor(MacClawStoreTheme.textMuted)
            }

            Section {
                ResourceRow(
                    label: "claw.setup.field.cpu.label",
                    value: "\(viewModel.cpuCores)",
                    canDecrement: viewModel.canDecrementCPU,
                    canIncrement: viewModel.canIncrementCPU,
                    onDecrement: viewModel.decrementCPU,
                    onIncrement: viewModel.incrementCPU
                )
                ResourceRow(
                    label: "claw.setup.field.ram.label",
                    value: "\(viewModel.ramMB)",
                    canDecrement: viewModel.canDecrementRAM,
                    canIncrement: viewModel.canIncrementRAM,
                    onDecrement: viewModel.decrementRAM,
                    onIncrement: viewModel.incrementRAM
                )
                if viewModel.showsDiskControl {
                    ResourceRow(
                        label: "claw.setup.field.disk.label",
                        value: "\(viewModel.diskGB)",
                        canDecrement: viewModel.canDecrementDisk,
                        canIncrement: viewModel.canIncrementDisk,
                        onDecrement: viewModel.decrementDisk,
                        onIncrement: viewModel.incrementDisk
                    )
                } else {
                    HStack {
                        Text("claw.setup.field.disk.label.short")
                            .font(MacTypography.Fonts.clawSetupBody)
                        Spacer()
                        Text("claw.setup.field.disk.managed")
                            .font(MacTypography.Fonts.clawSetupBody)
                            .foregroundColor(MacClawStoreTheme.textMuted)
                    }
                }
                if let warning = viewModel.resourceOptionsWarning {
                    Text(warning)
                        .font(MacTypography.Fonts.clawSetupCaption)
                        .foregroundColor(MacClawStoreTheme.accentAmber)
                }
            } header: {
                Text("claw.setup.section.resources")
                    .font(MacTypography.Fonts.clawSetupSection)
                    .foregroundColor(MacClawStoreTheme.textMuted)
            }

            Section {
                HStack {
                    Button(action: deploy) {
                        Text("claw.setup.button.deploy")
                            .font(MacTypography.Fonts.clawActionButton)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canDeploy)
                    if viewModel.isDeploying {
                        ProgressView().scaleEffect(0.6)
                    }
                    Spacer()
                }
                if viewModel.deploySucceeded {
                    Text("claw.setup.feedback.deploySucceeded")
                        .font(MacTypography.Fonts.clawSetupCaption)
                        .foregroundColor(MacClawStoreTheme.statusGreen)
                }
                if let err = viewModel.errorMessage {
                    Text(err)
                        .font(MacTypography.Fonts.clawSetupCaption)
                        .foregroundColor(MacClawStoreTheme.textWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(
            "claw.setup.navigationTitle \(viewModel.claw.name)",
            comment: "macOS navigation title for the claw deploy sheet. %@ = claw name (proper noun)."
        ))
        .frame(minWidth: 480, minHeight: 520)
        .task { await viewModel.loadOptions() }
        .onChange(of: viewModel.selectedServerIndex) { _, _ in
            Task { await viewModel.loadOptions() }
        }
    }

    private func deploy() {
        Task {
            await viewModel.deploy()
            if viewModel.deploySucceeded {
                // The monitor now owns progress UI; close the sheet so the
                // user can return to the store list.
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            }
        }
    }
}

private struct ResourceRow: View {
    let label: LocalizedStringKey
    let value: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(MacTypography.Fonts.clawSetupBody)
            Spacer()
            Button(action: onDecrement) { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .disabled(!canDecrement)
            Text(value)
                .font(MacTypography.Fonts.clawSetupValue)
                .monospacedDigit()
                .frame(minWidth: 52)
            Button(action: onIncrement) { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .disabled(!canIncrement)
        }
    }
}
