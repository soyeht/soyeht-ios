import SwiftUI
import SoyehtCore

/// Scene P9 — Face ID confirmation + owner readback + 6-word security code.
/// T053a: safety code words animate with `AnimationCatalog.staggerWord` (FR-128).
/// T053c: `glowActive` triggers `safetyGlow` animation + `HapticDirector.codeMatch` (FR-129).
struct BiometricConfirmView: View {
    let houseName: String
    let hostLabel: String
    /// Exactly 6 words (FR-045). Empty when not yet received from engine.
    let safetyWords: [String]
    let onConfirmed: () -> Void
    let onCancel: () -> Void

    @State private var glowActive = false
    @State private var safetyVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                dismissBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ownerReadback

                        if safetyWords.count == 6 {
                            safetyCodeSection
                        }

                        confirmButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear { safetyVisible = true }
    }

    private var dismissBar: some View {
        HStack {
            Button(action: onCancel) {
                Text(LocalizedStringResource(
                    "pairing.biometric.cancel",
                    defaultValue: "Cancel",
                    comment: "Cancel button on biometric confirm view."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var ownerReadback: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "pairing.biometric.title",
                defaultValue: "Confirm your identity",
                comment: "Biometric confirm screen title."
            ))
            .font(OnboardingFonts.heading)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "pairing.biometric.readback",
                defaultValue: "\(houseName) was just created on \(hostLabel).",
                comment: "Owner readback confirming house name and host machine."
            ))
            .font(OnboardingFonts.callout)
            .foregroundColor(BrandColors.textMuted)
        }
    }

    private var safetyCodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "pairing.biometric.codeHeader",
                defaultValue: "Security code",
                comment: "Section header for the 6-word safety code."
            ))
            .font(Font.footnote.weight(.semibold))
            .foregroundColor(BrandColors.textMuted)
            .textCase(.uppercase)
            .kerning(0.5)

            safetyCodeGrid

            Text(LocalizedStringResource(
                "pairing.biometric.codeHint",
                defaultValue: "Make sure the code on your Mac matches before confirming.",
                comment: "Instruction to verify safety codes match on both devices."
            ))
            .font(OnboardingFonts.footnote)
            .foregroundColor(BrandColors.textMuted)
        }
    }

    private var safetyCodeGrid: some View {
        VStack(spacing: 10) {
            wordRow(indices: 0..<3)
            wordRow(indices: 3..<6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    glowActive ? BrandColors.accentGreen : BrandColors.border,
                    lineWidth: glowActive ? 2 : 1
                )
                .shadow(
                    color: glowActive ? BrandColors.accentGreen.opacity(0.45) : .clear,
                    radius: 10
                )
                .animation(AnimationCatalog.safetyGlow(reduceMotion: reduceMotion), value: glowActive)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(safetyWords.joined(separator: " ")))
    }

    @ViewBuilder
    private func wordRow(indices: Range<Int>) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(indices), id: \.self) { idx in
                Text(verbatim: safetyWords[idx])
                    .font(Font.system(.title2, design: .monospaced))
                    .foregroundColor(BrandColors.textPrimary)
                    .opacity(safetyVisible ? 1 : 0)
                    .animation(
                        AnimationCatalog.staggerWord(wordIndex: idx, reduceMotion: reduceMotion),
                        value: safetyVisible
                    )
            }
        }
    }

    private var confirmButton: some View {
        Button(action: confirmTapped) {
            HStack(spacing: 10) {
                Image(systemName: "faceid")
                    .font(.system(size: 20))
                Text(LocalizedStringResource(
                    "pairing.biometric.confirm",
                    defaultValue: "Confirm with Face ID",
                    comment: "CTA: biometric confirm button. Used for both Face ID and Touch ID."
                ))
                .font(OnboardingFonts.bodyBold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BrandColors.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "pairing.biometric.confirm.a11y",
            defaultValue: "Confirm your identity with Face ID to join the home",
            comment: "VoiceOver label for biometric confirm button."
        )))
    }

    private func confirmTapped() {
        // T053c: safetyGlow animation + HapticDirector.codeMatch (FR-129)
        withAnimation(AnimationCatalog.safetyGlow(reduceMotion: reduceMotion)) {
            glowActive = true
        }
        HapticDirector.live().fire(.codeMatch)

        let glowDuration = reduceMotion ? 0.15 : 0.4
        Task {
            try? await Task.sleep(for: .seconds(glowDuration))
            onConfirmed()
        }
    }
}
