import SwiftUI
import SoyehtCore

/// MA2 — Install preview scene.
/// Shows what will happen during install (3 bullets) + opt-in telemetry toggle
/// (default OFF, FR-073) + Install CTA.
/// Per FR-011 (user sees what happens before confirming), FR-070 (telemetry opt-in
/// placement), FR-073 (genuine opt-in, default OFF).
struct InstallPreviewView: View {
    let onInstall: () -> Void

    @AppStorage("telemetry_opt_in") private var telemetryOptIn: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 28)

            header
                .padding(.bottom, 28)

            bullets
                .padding(.bottom, 28)

            telemetryRow

            Spacer()

            HStack {
                Spacer()
                Button(action: onInstall) {
                    Text(LocalizedStringResource(
                        "bootstrap.installPreview.cta",
                        defaultValue: "Install",
                        comment: "MA2: Primary CTA. Begins the install process."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(BrandColors.buttonTextOnAccent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 36)
                    .background(BrandColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "bootstrap.installPreview.cta.a11y",
                    defaultValue: "Install Soyeht on this Mac",
                    comment: "MA2 CTA VoiceOver label."
                )))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "bootstrap.installPreview.step",
            defaultValue: "Step 1 of 3",
            comment: "MA2: Step indicator. Same phase as MA1 (installation phase)."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.readableTextOnSelection)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.selection)
        .clipShape(Capsule())
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.installPreview.step.a11y",
            defaultValue: "Step 1 of 3",
            comment: "MA2 step indicator VoiceOver label."
        )))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringResource(
                "bootstrap.installPreview.title",
                defaultValue: "What will happen",
                comment: "MA2: Preview title explaining what the install will do."
            ))
            .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
            .foregroundColor(BrandColors.textPrimary)

            Text(LocalizedStringResource(
                "bootstrap.installPreview.subtitle",
                defaultValue: "Fast, quiet, and no administrator password.",
                comment: "MA2: Subtitle reinforcing zero-sudo install."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textMuted)
        }
    }

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 14) {
            BulletRow(
                title: LocalizedStringResource(
                    "bootstrap.installPreview.bullet1.title",
                    defaultValue: "Soyeht stays active on this Mac",
                    comment: "MA2 bullet 1: engine runs as a background LaunchAgent."
                ),
                detail: LocalizedStringResource(
                    "bootstrap.installPreview.bullet1.body",
                    defaultValue: "A lightweight engine runs in the background, ready to answer agents.",
                    comment: "MA2 bullet 1 detail: describes the background engine."
                )
            )

            BulletRow(
                title: LocalizedStringResource(
                    "bootstrap.installPreview.bullet2.title",
                    defaultValue: "Starts automatically at login",
                    comment: "MA2 bullet 2: LaunchAgent auto-starts at login."
                ),
                detail: LocalizedStringResource(
                    "bootstrap.installPreview.bullet2.body",
                    defaultValue: "Soyeht appears in the menu when you open the computer.",
                    comment: "MA2 bullet 2 detail: auto-launch behavior."
                )
            )

            BulletRow(
                title: LocalizedStringResource(
                    "bootstrap.installPreview.bullet3.title",
                    defaultValue: "No administrator password",
                    comment: "MA2 bullet 3: zero sudo required (FR-012)."
                ),
                detail: LocalizedStringResource(
                    "bootstrap.installPreview.bullet3.body",
                    defaultValue: "No password prompt appears now or later.",
                    comment: "MA2 bullet 3 detail: zero sudo guarantee."
                )
            )
        }
    }

    private var telemetryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $telemetryOptIn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource(
                        "bootstrap.installPreview.telemetry.label",
                        defaultValue: "Send anonymous data to improve Soyeht",
                        comment: "MA2: Telemetry opt-in toggle label. Default OFF per FR-073."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textPrimary)

                    Text(LocalizedStringResource(
                        "bootstrap.installPreview.telemetry.note",
                        defaultValue: "No personal information. You can change this later in Settings.",
                        comment: "MA2: Telemetry note below toggle. Reassures no PII."
                    ))
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.textMuted)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text(LocalizedStringResource(
                "bootstrap.installPreview.telemetry.a11y",
                defaultValue: "Option to send anonymous usage data",
                comment: "MA2: VoiceOver label for the telemetry toggle."
            )))
        }
    }
}

private struct BulletRow: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(BrandColors.accentGreen)
                .font(.system(size: 16))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .fontWeight(.semibold)
                    .foregroundColor(BrandColors.textPrimary)
                Text(detail)
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
