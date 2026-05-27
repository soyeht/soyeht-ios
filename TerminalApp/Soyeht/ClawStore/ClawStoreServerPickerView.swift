import SwiftUI
import SoyehtCore

/// Shown when the user taps the home Claw Store button and there are 2+
/// paired servers. Asks the user to pick the server *before* opening the
/// catalog, so the install/deploy actions downstream are unambiguous.
///
/// Lists every server `ServerRegistry.shared.servers` knows about, but
/// rows whose `ClawInstallTargetResolver.resolve` returns
/// `.unavailable(.missingContext)` render disabled with the same
/// product copy as `MacClawUnavailableView`. The user does not have to
/// tap-and-discover that a particular Mac can't be managed directly —
/// the picker tells them up front.
///
/// Macs render in a `// macs` section; Linux hosts in a `// linux`
/// section. Single-section households skip the section header entirely.
struct ClawStoreServerPickerView: View {
    @ObservedObject var registry: ServerRegistry
    let onSelect: (ClawInstallTarget) -> Void
    let onBack: () -> Void

    init(
        registry: ServerRegistry? = nil,
        onSelect: @escaping (ClawInstallTarget) -> Void,
        onBack: @escaping () -> Void
    ) {
        // `registry` defaults to nil and resolves to `.shared` inside
        // this MainActor init — the shorthand `= .shared` in the
        // signature is rejected by Swift 6 strict concurrency since
        // default-value expressions evaluate in a non-isolated context.
        self.registry = registry ?? ServerRegistry.shared
        self.onSelect = onSelect
        self.onBack = onBack
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !macServers.isEmpty {
                            section(
                                title: LocalizedStringResource(
                                    "clawstore.picker.section.macs",
                                    defaultValue: "// macs",
                                    comment: "Section header in the server picker for Mac servers."
                                ),
                                servers: macServers
                            )
                        }
                        if !linuxServers.isEmpty {
                            section(
                                title: LocalizedStringResource(
                                    "clawstore.picker.section.linux",
                                    defaultValue: "// linux",
                                    comment: "Section header in the server picker for Linux servers."
                                ),
                                servers: linuxServers
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .accessibilityIdentifier(AccessibilityID.ClawStore.serverPickerList)
            }
            .padding(.top, 8)
        }
        .navigationBarHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text(verbatim: "<")
                        .font(Typography.monoPageTitle)
                        .foregroundColor(SoyehtTheme.accentGreen)
                }
                Text(LocalizedStringResource(
                    "clawstore.picker.title",
                    defaultValue: "Pick a Server",
                    comment: "Title for the Claw Store server picker — shown when 2+ servers are paired."
                ))
                    .font(Typography.monoPageTitle)
                    .foregroundColor(SoyehtTheme.textPrimary)
            }
            Text(LocalizedStringResource(
                "clawstore.picker.subtitle",
                defaultValue: "Pick the server you want to install Claws on.",
                comment: "Subtitle for the Claw Store server picker."
            ))
                .font(Typography.monoCardBody)
                .foregroundColor(SoyehtTheme.textComment)
        }
        .padding(.horizontal, 20)
    }

    private var macServers: [Server] {
        registry.servers.filter { $0.kind == .mac }
    }

    private var linuxServers: [Server] {
        registry.servers.filter { $0.kind == .linux }
    }

    private func section(title: LocalizedStringResource, servers: [Server]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.monoSectionLabel)
                .foregroundColor(SoyehtTheme.textComment)
            VStack(spacing: 8) {
                ForEach(servers, id: \.id) { server in
                    row(for: server)
                }
            }
        }
    }

    private func row(for server: Server) -> some View {
        let target = ClawInstallTarget(serverID: server.id)
        let resolution = ClawInstallTargetResolver.resolve(target, registry: registry)
        let isDisabled: Bool
        if case .unavailable(.missingContext) = resolution {
            isDisabled = true
        } else {
            isDisabled = false
        }

        return Button(action: {
            guard !isDisabled else { return }
            onSelect(target)
        }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: server.kind == .mac ? "desktopcomputer" : "terminal")
                    .font(Typography.monoBody)
                    .foregroundColor(
                        isDisabled
                            ? SoyehtTheme.textTertiary
                            : SoyehtTheme.historyGreen
                    )
                    .frame(width: 18, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(server.displayName)
                        .font(Typography.monoCardTitle)
                        .foregroundColor(
                            isDisabled
                                ? SoyehtTheme.textSecondary
                                : SoyehtTheme.textPrimary
                        )
                        .lineLimit(1)

                    Text(server.lastHost ?? server.hostname)
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textComment)
                        .lineLimit(1)

                    if isDisabled {
                        Text(LocalizedStringResource(
                            "clawstore.picker.row.needsUpdate",
                            defaultValue: "Needs Soyeht update for direct Claw management",
                            comment: "Subtitle below a server row in the picker when direct Claw management is not available for that server yet."
                        ))
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.accentAmber)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                if !isDisabled {
                    Text(verbatim: ">")
                        .font(Typography.monoLabelRegular)
                        .foregroundColor(SoyehtTheme.textComment)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoyehtTheme.bgPrimary)
            .overlay(
                Rectangle().stroke(
                    isDisabled ? SoyehtTheme.bgCardBorder : SoyehtTheme.historyGreen.opacity(0.5),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier(AccessibilityID.ClawStore.serverPickerRow(server.id))
    }
}
