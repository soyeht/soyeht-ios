import SwiftUI
import SoyehtCore
import AppKit

/// House naming scene (post-install).
/// Pre-fills the name field with "<first name>'s Home" per FR-015.
/// Validates: 1–32 chars, no filesystem-forbidden characters (/:\*?"<>|).
struct HouseNamingView: View {
    let onNamed: (String) -> Void

    @State private var houseName: String = Self.suggestedName()
    @FocusState private var isTextFieldFocused: Bool

    private static let maxLength = 32
    private static let forbiddenChars = CharacterSet(charactersIn: "/:\\*?\"<>|")

    var body: some View {
        WelcomeStepScaffold(
            step: 3,
            title: LocalizedStringResource(
                "bootstrap.houseNaming.title",
                defaultValue: "Name your home.",
                comment: "M3: title of the naming step."
            ),
            body: LocalizedStringResource(
                "bootstrap.houseNaming.explainer",
                defaultValue: "Your home is this Mac plus the devices you add to it. The name is what you will see on your iPhone.",
                comment: "M3: explains what a home is, in the owner's terms, before they name one."
            ),
            content: { nameField },
            footer: {
                HStack {
                    Spacer()
                    Button(action: confirm) {
                        Text(LocalizedStringResource(
                            "bootstrap.houseNaming.cta",
                            defaultValue: "Continue",
                            comment: "M3: button that creates the home."
                        ))
                    }
                    .buttonStyle(NeoPillButtonStyle(.primary, palette: NeoPalette.cloud, fillsWidth: false))
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.5)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(WelcomeAccessibilityID.m3Continue)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "bootstrap.houseNaming.cta.a11y",
                        defaultValue: "Create the home with the provided name",
                        comment: "House naming CTA VoiceOver label."
                    )))
                }
            }
        )
        .onAppear { isTextFieldFocused = true }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "bootstrap.houseNaming.field.placeholder",
                text: $houseName
            )
            .textFieldStyle(NeoTextFieldStyle(palette: NeoPalette.cloud))
            .focused($isTextFieldFocused)
            .onChange(of: houseName) { _, new in
                // Strip forbidden chars on input and cap length
                let cleaned = new.unicodeScalars
                    .filter { !Self.forbiddenChars.contains($0) }
                    .map { Character($0) }
                let clamped = String(cleaned.prefix(Self.maxLength))
                if clamped != new { houseName = clamped }
            }
            .accessibilityIdentifier(WelcomeAccessibilityID.m3NameField)
            .accessibilityLabel(Text(LocalizedStringResource(
                "bootstrap.houseNaming.field.a11y",
                defaultValue: "Home name, \(houseName.count) of \(Self.maxLength) characters",
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
                    defaultValue: "Some characters are not allowed in the name.",
                    comment: "Validation message for forbidden filesystem characters."
                ))
                .font(NeoFont.caption)
                .foregroundStyle(NeoPalette.cloud.danger)
            }
            Spacer()
            Text(LocalizedStringResource(
                "bootstrap.houseNaming.charCount",
                defaultValue: "\(houseName.count)/\(Self.maxLength)",
                comment: "Character count display for house name field."
            ))
            .font(NeoFont.caption)
            .foregroundStyle(houseName.count >= Self.maxLength ? NeoPalette.cloud.danger : NeoPalette.cloud.muted)
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

    /// Suggested name from NSFullUserName().firstWord.
    private static func suggestedName() -> String {
        let full = NSFullUserName()
        let first = full.components(separatedBy: .whitespaces).first ?? full
        let prefix = String(localized: "bootstrap.houseNaming.suggestedPrefix", defaultValue: "Home")
        return "\(prefix) \(first)"
    }
}
