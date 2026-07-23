import SwiftUI
import SoyehtCore

/// Card representing a single Claw in the marketplace grid. Always
/// clickable (drives navigation to the detail view); the install button
/// is only rendered when the caller asks for it.
struct MacClawCardView: View {
    let claw: Claw
    /// E2a: the live guest-image readiness, so the dedicated Store card consults
    /// the SAME `MacClawInstallDecision` as the drawer instead of a pre-computed
    /// bool + an inline `.notInstalled`-only rule (which made `.installFailed` a
    /// dead-end on the card while the drawer/detail/iOS all offer retry). Defaults
    /// to `.unavailable` (fail-closed) for any card rendered without readiness.
    var readiness: MacGuestImageGateState = .unavailable
    var onInstall: (() -> Void)?
    var onTap: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tappable region — drives navigation to the detail view.
            Button {
                onTap?()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(claw.name)
                            .font(MacTypography.Fonts.clawCardTitle)
                            .foregroundColor(MacClawStoreTheme.textPrimary)
                        Spacer()
                        Text(claw.language.capitalized)
                            .font(MacTypography.Fonts.clawCardLanguage)
                            .foregroundColor(MacClawStoreTheme.statusGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MacClawStoreTheme.statusGreenBg)
                            .clipShape(Capsule())
                    }

                    Text(claw.description)
                        .font(MacTypography.Fonts.clawCardBody)
                        .foregroundColor(MacClawStoreTheme.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Label(claw.displayMinRAM, systemImage: "memorychip")
                            .font(MacTypography.Fonts.clawCardMeta)
                            .foregroundColor(MacClawStoreTheme.textSecondary)
                        Label(claw.displayVersion, systemImage: "tag")
                            .font(MacTypography.Fonts.clawCardMeta)
                            .foregroundColor(MacClawStoreTheme.textSecondary)
                    }

                    stateRow
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Install button lives outside the navigation button so clicks
            // on it do NOT also trigger navigation.
            // E2a: the single shared decision — same as the drawer row — so the
            // Store card can't diverge (now offers retry on `.installFailed`, and
            // honors the guest-image readiness gate). No rule re-derived here.
            if MacClawInstallDecision.canOfferInstall(claw: claw, readiness: readiness, isInstalling: false),
               let onInstall {
                Button(action: onInstall) {
                    Text("claw.card.button.install")
                        .font(MacTypography.Fonts.clawActionButton)
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: MacSurface.Radius.card).stroke(effectiveBorderColor, lineWidth: MacSurface.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSurface.Radius.card))
        .shadow(color: neoDualShadowDark, radius: 5, x: 5, y: 5)
        .shadow(color: neoDualShadowLight, radius: 5, x: -5, y: -5)
        .onHover { hovering = $0 }
    }

    private var neo: Bool { MacSurface.style == .neomorphic }

    /// Generator-style convex surface in neo (SwiftUI does the dual shadows
    /// natively via the two `.shadow` modifiers above, which resolve to
    /// `.clear` in classic); flat themed fill otherwise.
    @ViewBuilder private var cardBackground: some View {
        if neo {
            LinearGradient(
                colors: [
                    Color(nsColor: MacTheme.neoConvexStart),
                    Color(nsColor: MacTheme.neoConvexEnd),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(hovering ? 0.9 : 1)
        } else {
            hovering ? MacClawStoreTheme.bgRowHover : MacClawStoreTheme.bgCard
        }
    }

    private var neoDualShadowDark: Color {
        neo ? Color(nsColor: MacTheme.neoShadowDark) : .clear
    }

    private var neoDualShadowLight: Color {
        neo ? Color(nsColor: MacTheme.neoShadowLight) : .clear
    }

    /// Install-state borders stay in neo (they carry meaning); only the
    /// default hairline is dropped — depth replaces it.
    private var hasStateBorder: Bool {
        switch claw.installState {
        case .installed, .installedButBlocked, .installing, .uninstalling, .installFailed:
            return true
        default:
            return false
        }
    }

    private var effectiveBorderColor: Color {
        (neo && !hasStateBorder) ? .clear : borderColor
    }

    private var borderColor: Color {
        switch claw.installState {
        case .installed:                return MacClawStoreTheme.statusGreen
        case .installedButBlocked:      return MacClawStoreTheme.accentAmber
        case .installing, .uninstalling: return MacClawStoreTheme.statusGreenStrong
        case .installFailed:            return MacClawStoreTheme.textWarning
        default:                        return MacClawStoreTheme.bgCardBorder
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        // Installability (theyos #88) takes precedence: a non-installable
        // claw reads "not available" instead of its install-state label.
        if !claw.installability.isInstallable {
            Text(LocalizedStringResource(
                "claw.card.state.unavailable",
                defaultValue: "Not available",
                comment: "Claw card state row when the backend reports the claw is not installable."
            ))
                .font(MacTypography.Fonts.clawCardState)
                .foregroundColor(MacClawStoreTheme.textComment)
        } else {
            stateRowForInstallState
        }
    }

    @ViewBuilder
    private var stateRowForInstallState: some View {
        switch claw.installState {
        case .installed:
            Text("claw.card.state.installed")
                .font(MacTypography.Fonts.clawCardStateStrong)
                .foregroundColor(MacClawStoreTheme.statusGreen)
        case .installedButBlocked(let reasons):
            if let firstReason = reasons.first {
                Text(firstReason.displayMessage)
                    .font(MacTypography.Fonts.clawCardStateStrong)
                    .foregroundColor(MacClawStoreTheme.accentAmber)
            } else {
                Text("claw.card.state.blocked")
                    .font(MacTypography.Fonts.clawCardStateStrong)
                    .foregroundColor(MacClawStoreTheme.accentAmber)
            }
        case .installing(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress?.fraction ?? 0.1)
                    .progressViewStyle(.linear)
                    .tint(MacClawStoreTheme.statusGreen)
                Text(verbatim: "\(progress?.percent ?? 0)%")
                    .font(MacTypography.Fonts.clawCardState)
                    .foregroundColor(MacClawStoreTheme.textMuted)
            }
        case .uninstalling:
            Text("claw.card.state.uninstalling")
                .font(MacTypography.Fonts.clawCardState)
                .foregroundColor(MacClawStoreTheme.textMuted)
        case .installFailed(let err):
            Text(LocalizedStringResource(
                "claw.card.state.installFailed",
                defaultValue: "Failed: \(err)",
                comment: "Claw card status row when the last install attempt errored. %@ = underlying error (already localized / server-provided)."
            ))
                .font(MacTypography.Fonts.clawCardState)
                .foregroundColor(MacClawStoreTheme.textWarning)
                .lineLimit(2)
        case .notInstalled:
            Text("claw.card.state.notInstalled")
                .font(MacTypography.Fonts.clawCardState)
                .foregroundColor(MacClawStoreTheme.textComment)
        case .unknown:
            Text("claw.card.state.unknown")
                .font(MacTypography.Fonts.clawCardState)
                .foregroundColor(MacClawStoreTheme.textWarning)
        }
    }
}
