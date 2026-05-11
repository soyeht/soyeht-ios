import SwiftUI
import SoyehtCore
import AppKit

/// House naming scene (post-install).
/// Pre-fills the name field with "Casa <NSFullUserName().firstWord>" per FR-015.
/// Validates: 1–32 chars, no filesystem-forbidden characters (/:\*?"<>|).
struct HouseNamingView: View {
    let onNamed: (String) -> Void

    @State private var houseName: String = Self.suggestedName()
    @FocusState private var isTextFieldFocused: Bool

    private static let maxLength = 32
    private static let forbiddenChars = CharacterSet(charactersIn: "/:\\*?\"<>|")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringResource(
                    "bootstrap.houseNaming.title",
                    defaultValue: "Como você quer chamar sua casa?",
                    comment: "House naming scene title."
                ))
                .font(MacTypography.Fonts.Display.heroTitle)
                .foregroundColor(BrandColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "bootstrap.houseNaming.subtitle",
                    defaultValue: "Você pode mudar isso depois.",
                    comment: "House naming subtitle reassuring name is changeable."
                ))
                .font(MacTypography.Fonts.Display.heroSubtitle)
                .foregroundColor(BrandColors.textMuted)
            }
            .padding(.bottom, 32)

            nameField

            Spacer()

            HStack {
                Spacer()
                Button(action: confirm) {
                    Text(LocalizedStringResource(
                        "bootstrap.houseNaming.cta",
                        defaultValue: "Criar Casa",
                        comment: "House naming CTA. Submits the name and starts key generation."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                    .foregroundColor(BrandColors.buttonTextOnAccent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 28)
                    .background(isValid ? BrandColors.accentGreen : BrandColors.border)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "bootstrap.houseNaming.cta.a11y",
                    defaultValue: "Criar a casa com o nome fornecido",
                    comment: "House naming CTA VoiceOver label."
                )))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { isTextFieldFocused = true }
    }

    private var stepIndicator: some View {
        Text(LocalizedStringResource(
            "bootstrap.houseNaming.step",
            defaultValue: "Passo 2 de 3",
            comment: "House naming step indicator."
        ))
        .font(MacTypography.Fonts.welcomeProgressTitle)
        .foregroundColor(BrandColors.readableTextOnSelection)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BrandColors.selection)
        .clipShape(Capsule())
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "bootstrap.houseNaming.field.placeholder",
                text: $houseName
            )
            .textFieldStyle(.plain)
            .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
            .foregroundColor(BrandColors.textPrimary)
            .focused($isTextFieldFocused)
            .onChange(of: houseName) { _, new in
                // Strip forbidden chars on input and cap length
                let cleaned = new.unicodeScalars
                    .filter { !Self.forbiddenChars.contains($0) }
                    .map { Character($0) }
                let clamped = String(cleaned.prefix(Self.maxLength))
                if clamped != new { houseName = clamped }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(BrandColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isTextFieldFocused ? BrandColors.accentGreen : BrandColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(Text(LocalizedStringResource(
                "bootstrap.houseNaming.field.a11y",
                defaultValue: "Nome da casa, \(houseName.count) de \(Self.maxLength) caracteres",
                comment: "House naming field VoiceOver label with char count."
            )))

            characterCount
        }
    }

    private var characterCount: some View {
        HStack {
            if hasForbiddenChars {
                Text(LocalizedStringResource(
                    "bootstrap.houseNaming.validation.forbidden",
                    defaultValue: "Alguns caracteres não são permitidos no nome.",
                    comment: "Validation message for forbidden filesystem characters."
                ))
                .font(MacTypography.Fonts.welcomeProgressBody)
                .foregroundColor(BrandColors.accentAmber)
            }
            Spacer()
            Text(LocalizedStringResource(
                "bootstrap.houseNaming.charCount",
                defaultValue: "\(houseName.count)/\(Self.maxLength)",
                comment: "Character count display for house name field."
            ))
            .font(MacTypography.Fonts.welcomeProgressBody)
            .foregroundColor(houseName.count >= Self.maxLength ? BrandColors.accentAmber : BrandColors.textMuted)
            .accessibilityHidden(true)
        }
    }

    private var hasForbiddenChars: Bool {
        houseName.unicodeScalars.contains { Self.forbiddenChars.contains($0) }
    }

    private var isValid: Bool {
        let trimmed = houseName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && trimmed.count <= Self.maxLength
            && !hasForbiddenChars
    }

    private func confirm() {
        let trimmed = houseName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onNamed(trimmed)
    }

    /// "Casa Caio" from NSFullUserName().firstWord.
    private static func suggestedName() -> String {
        let full = NSFullUserName()
        let first = full.components(separatedBy: .whitespaces).first ?? full
        return "Casa \(first)"
    }
}
