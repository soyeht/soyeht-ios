import SwiftUI
import SoyehtCore

/// Cena P9 — Face ID confirmation + owner readback + 6-word código de segurança.
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
                    defaultValue: "Cancelar",
                    comment: "Cancel button on biometric confirm view."
                ))
                .font(.system(size: 15))
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
                defaultValue: "Confirme sua identidade",
                comment: "Biometric confirm screen title."
            ))
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "pairing.biometric.readback",
                defaultValue: "\(houseName) foi criada agora há pouco no \(hostLabel).",
                comment: "Owner readback confirming house name and host machine."
            ))
            .font(.system(size: 16))
            .foregroundColor(BrandColors.textMuted)
        }
    }

    private var safetyCodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "pairing.biometric.codeHeader",
                defaultValue: "Código de segurança",
                comment: "Section header for the 6-word safety code."
            ))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(BrandColors.textMuted)
            .textCase(.uppercase)
            .kerning(0.5)

            safetyCodeGrid

            Text(LocalizedStringResource(
                "pairing.biometric.codeHint",
                defaultValue: "Certifique-se que o código no Mac é idêntico antes de confirmar.",
                comment: "Instruction to verify safety codes match on both devices."
            ))
            .font(.system(size: 13))
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
                    .font(.system(size: 22, design: .monospaced))
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
                    defaultValue: "Confirmar com Face ID",
                    comment: "CTA: biometric confirm button. Used for both Face ID and Touch ID."
                ))
                .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BrandColors.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "pairing.biometric.confirm.a11y",
            defaultValue: "Confirmar identidade com Face ID para entrar na casa",
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
