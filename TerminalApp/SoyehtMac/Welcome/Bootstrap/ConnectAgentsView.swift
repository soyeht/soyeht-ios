import SwiftUI
import SoyehtCore

/// Onboarding step that wires Soyeht into the user's AI agent CLIs so
/// `@soyeht` / `mcp__soyeht__*` tools work without any terminal commands.
/// Inserted between `InstallProgressView` (engine ready) and `HouseNamingView`
/// in the bootstrap flow.
struct ConnectAgentsView: View {
    let onContinue: () -> Void

    @State private var detected: [AIAgentIntegrator.Agent: Bool] = [:]
    @State private var selection: Set<AIAgentIntegrator.Agent> = []
    @State private var isInstalling = false
    @State private var errorMessage: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 24)

            Text(LocalizedStringResource(
                "bootstrap.connectAgents.title",
                defaultValue: "Connect your AI agents",
                comment: "Title of the onboarding step that registers the Soyeht MCP with each installed agent CLI."
            ))
            .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
            .foregroundColor(BrandColors.textPrimary)
            .padding(.bottom, 12)

            Text(LocalizedStringResource(
                "bootstrap.connectAgents.body",
                defaultValue: "Let your AI agents open files, run shells, and manage panes here. Pick which agents to connect — you can change this later.",
                comment: "Short copy under the Connect AI Agents title explaining what the MCP enables."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(AIAgentIntegrator.Agent.allCases) { agent in
                    AgentRow(
                        agent: agent,
                        isInstalled: detected[agent] ?? false,
                        isSelected: selection.contains(agent),
                        onToggle: { toggle(agent) }
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }

            Spacer()

            HStack(spacing: 12) {
                Spacer()
                Button(action: skip) {
                    Text(LocalizedStringResource(
                        "bootstrap.connectAgents.skip",
                        defaultValue: "Skip",
                        comment: "Button to skip wiring up the MCP — user can run it later from preferences."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(BrandColors.textMuted)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                }
                .buttonStyle(.plain)
                .disabled(isInstalling)

                Button(action: confirm) {
                    HStack(spacing: 8) {
                        if isInstalling {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(BrandColors.buttonTextOnAccent)
                        }
                        Text(continueTitle)
                            .font(MacTypography.Fonts.Controls.cta)
                            .foregroundColor(BrandColors.buttonTextOnAccent)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 22)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(canConfirm ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!canConfirm)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await refreshDetection() }
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "bootstrap.connectAgents.step",
            defaultValue: "Step 2 of 3",
            comment: "Step indicator capsule for the connect-agents onboarding step."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.readableTextOnSelection)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.selection)
        .clipShape(Capsule())
    }

    private var canConfirm: Bool {
        !isInstalling
    }

    private var continueTitle: LocalizedStringResource {
        if selection.isEmpty {
            return LocalizedStringResource(
                "bootstrap.connectAgents.continueNone",
                defaultValue: "Continue without connecting",
                comment: "Continue button label when the user did not pick any agent."
            )
        }
        return LocalizedStringResource(
            "bootstrap.connectAgents.continue",
            defaultValue: "Connect and continue",
            comment: "Continue button label that runs the MCP install for the picked agents."
        )
    }

    private func toggle(_ agent: AIAgentIntegrator.Agent) {
        guard detected[agent] == true else { return }
        if selection.contains(agent) { selection.remove(agent) }
        else { selection.insert(agent) }
    }

    private func refreshDetection() async {
        let result = await MainActor.run { AIAgentIntegrator.detectAll() }
        await MainActor.run {
            detected = result
            // Default selection: every detected agent. Caio's preference is
            // "if you have it installed, connect it" — opt-out, not opt-in.
            selection = Set(result.compactMap { $0.value ? $0.key : nil })
        }
    }

    private func skip() {
        onContinue()
    }

    private func confirm() {
        guard !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        let agents = Array(selection)
        Task.detached(priority: .userInitiated) {
            do {
                try AIAgentIntegrator.install(for: agents)
                await MainActor.run {
                    isInstalling = false
                    onContinue()
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    errorMessage = LocalizedStringResource(
                        "bootstrap.connectAgents.installFailed",
                        defaultValue: "Couldn't update one of the agent configs. You can try again from Preferences later.",
                        comment: "Inline error shown when the MCP integrator fails to write a config file."
                    )
                }
            }
        }
    }
}

private struct AgentRow: View {
    let agent: AIAgentIntegrator.Agent
    let isInstalled: Bool
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                checkbox
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                        .foregroundColor(isInstalled ? BrandColors.textPrimary : BrandColors.textMuted)
                    if !isInstalled {
                        Text(LocalizedStringResource(
                            "bootstrap.connectAgents.notInstalled",
                            defaultValue: "Not installed",
                            comment: "Hint shown next to an AI agent the user does not have on PATH."
                        ))
                        .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                        .foregroundColor(BrandColors.textMuted)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? BrandColors.selection.opacity(0.5) : BrandColors.surfaceDeep)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInstalled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(isSelected ? "selected" : "not selected"))
    }

    @ViewBuilder private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.system(size: 18))
            .foregroundColor(
                !isInstalled ? BrandColors.textMuted :
                (isSelected ? BrandColors.accentGreen : BrandColors.border)
            )
            .accessibilityHidden(true)
    }
}
