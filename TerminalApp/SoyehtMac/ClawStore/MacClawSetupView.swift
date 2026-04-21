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

    init(claw: Claw) {
        _viewModel = StateObject(wrappedValue: ClawSetupViewModel(claw: claw))
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(viewModel.claw.name)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("v\(viewModel.claw.displayVersion)")
                        .foregroundColor(MacClawStoreTheme.textMuted)
                }
                TextField("Nome da instância", text: $viewModel.clawName)
                    .textFieldStyle(.roundedBorder)
                if let error = viewModel.nameValidationError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(MacClawStoreTheme.accentAmber)
                }
            } header: {
                Text("Instância").foregroundColor(MacClawStoreTheme.textMuted)
            }

            Section {
                Picker("Servidor", selection: $viewModel.selectedServerIndex) {
                    ForEach(Array(viewModel.servers.enumerated()), id: \.offset) { idx, server in
                        Text("\(server.name) · \(server.host)").tag(idx)
                    }
                }
                .pickerStyle(.menu)

                Picker("Guest OS", selection: $viewModel.serverType) {
                    Text("Linux").tag("linux")
                    Text("macOS").tag("macos")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Destino").foregroundColor(MacClawStoreTheme.textMuted)
            }

            Section {
                ResourceRow(
                    label: "CPU cores",
                    value: "\(viewModel.cpuCores)",
                    canDecrement: viewModel.canDecrementCPU,
                    canIncrement: viewModel.canIncrementCPU,
                    onDecrement: viewModel.decrementCPU,
                    onIncrement: viewModel.incrementCPU
                )
                ResourceRow(
                    label: "RAM (MB)",
                    value: "\(viewModel.ramMB)",
                    canDecrement: viewModel.canDecrementRAM,
                    canIncrement: viewModel.canIncrementRAM,
                    onDecrement: viewModel.decrementRAM,
                    onIncrement: viewModel.incrementRAM
                )
                if viewModel.showsDiskControl {
                    ResourceRow(
                        label: "Disco (GB)",
                        value: "\(viewModel.diskGB)",
                        canDecrement: viewModel.canDecrementDisk,
                        canIncrement: viewModel.canIncrementDisk,
                        onDecrement: viewModel.decrementDisk,
                        onIncrement: viewModel.incrementDisk
                    )
                } else {
                    HStack {
                        Text("Disco")
                        Spacer()
                        Text("Gerenciado pelo servidor")
                            .foregroundColor(MacClawStoreTheme.textMuted)
                    }
                }
                if let warning = viewModel.resourceOptionsWarning {
                    Text(warning)
                        .font(.system(size: 10))
                        .foregroundColor(MacClawStoreTheme.accentAmber)
                }
            } header: {
                Text("Recursos").foregroundColor(MacClawStoreTheme.textMuted)
            }

            Section {
                HStack {
                    Button("Deploy", action: deploy)
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canDeploy)
                    if viewModel.isDeploying {
                        ProgressView().scaleEffect(0.6)
                    }
                    Spacer()
                }
                if viewModel.deploySucceeded {
                    Text("Instância criada. Acompanhe o provisionamento no painel.")
                        .font(.system(size: 11))
                        .foregroundColor(MacClawStoreTheme.statusGreen)
                }
                if let err = viewModel.errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(MacClawStoreTheme.textWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Deploy \(viewModel.claw.name)")
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
    let label: String
    let value: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(action: onDecrement) { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canDecrement)
            Text(value)
                .monospacedDigit()
                .frame(minWidth: 52)
            Button(action: onIncrement) { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canIncrement)
        }
    }
}
