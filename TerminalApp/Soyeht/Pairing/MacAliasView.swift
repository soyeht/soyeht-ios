import SwiftUI
import SoyehtCore

// MARK: - Mac Alias Screen
//
// Mandatory naming step shown whenever a `PairedMac` has `needsAlias == true`.
// There is no skip button on purpose: the product invariant is that no UI
// surface ever shows the hostname (e.g. "macStudio") after onboarding —
// every Mac the user sees must already have a user-typed name.
//
// The single mutator is `PairedMacsStore.setAlias`, which enforces validation
// rules (see `MacAliasValidator`) and duplicate detection across all paired
// Macs in the same household. This view delegates entirely to that contract;
// do not duplicate the rules here.
//
// Presentation: full-screen cover from `InstanceListView` whenever any mac
// in `PairedMacsStoreObservable.shared.macs` needs naming. Multiple unnamed
// Macs (e.g. after a fresh install that inherits Keychain-restored Macs) are
// handled one at a time.
struct MacAliasView: View {
    let mac: PairedMac
    let onNamed: () -> Void

    @State private var alias: String
    @State private var errorMessage: LocalizedStringResource?
    @FocusState private var isFocused: Bool

    init(mac: PairedMac, onNamed: @escaping () -> Void) {
        self.mac = mac
        self.onNamed = onNamed
        // Pre-fill with the current alias (rename flow) or the hostname
        // (first-time naming flow). The same view backs both call sites
        // because the validation + dedupe rules are identical; only the
        // presentation modifier differs (mandatory full-screen cover vs.
        // dismissable rename sheet).
        _alias = State(initialValue: mac.alias ?? mac.name)
    }

    private var isValid: Bool {
        if case .success = MacAliasValidator.validate(alias) { return true }
        return false
    }

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(LocalizedStringResource(
                                "macAlias.title",
                                defaultValue: "What do you want to call this Mac?",
                                comment: "Mac alias screen title — user names a paired Mac."
                            ))
                            .font(OnboardingFonts.heading)
                            .foregroundColor(BrandColors.textPrimary)
                            .accessibilityAddTraits(.isHeader)

                            Text(LocalizedStringResource(
                                "macAlias.subtitle",
                                defaultValue: "Pick a short name you will recognise — you can rename it later in Settings.",
                                comment: "Mac alias screen subtitle, reassures the user that the name is editable."
                            ))
                            .font(OnboardingFonts.subheadline)
                            .foregroundColor(BrandColors.textMuted)
                        }

                        nameField

                        if let errorMessage {
                            Text(errorMessage)
                                .font(OnboardingFonts.footnote)
                                .foregroundColor(BrandColors.accentAmber)
                                .accessibilityIdentifier("macAlias.error")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                    .padding(.bottom, 40)
                }

                Spacer(minLength: 0)

                ctaBar
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear { isFocused = true }
        // Interactive dismiss is controlled by the *presenting* call site:
        // - First-time naming (`InstanceListView` full-screen cover) wraps
        //   this view with `.interactiveDismissDisabled()` to enforce the
        //   "no skip" product rule.
        // - Rename (`PairedMacsListView` sheet) allows swipe-down to cancel.
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                String(localized: LocalizedStringResource(
                    "macAlias.field.placeholder",
                    defaultValue: "Name this Mac",
                    comment: "Placeholder text inside the Mac alias text field."
                )),
                text: $alias
            )
            .focused($isFocused)
            .font(Font.title2.weight(.medium))
            .foregroundColor(BrandColors.textPrimary)
            .submitLabel(.done)
            .onChange(of: alias) { new in
                // Live-strip forbidden characters and enforce the max length
                // so the field cannot drift out of `MacAliasValidator`'s rules.
                let cleaned = new.unicodeScalars
                    .filter { !MacAliasRules.forbiddenChars.contains($0) }
                    .map { Character($0) }
                let clamped = String(cleaned.prefix(MacAliasRules.maxLength))
                if clamped != new { alias = clamped }
                errorMessage = nil
            }
            .onSubmit { if isValid { submit() } }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(BrandColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? BrandColors.accentGreen : BrandColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("macAlias.field")
            .accessibilityLabel(Text(LocalizedStringResource(
                "macAlias.field.a11y",
                defaultValue: "Mac name, \(alias.count) of \(MacAliasRules.maxLength) characters",
                comment: "Mac alias field VoiceOver label with character count."
            )))

            HStack {
                Spacer()
                Text(LocalizedStringResource(
                    "macAlias.charCount",
                    defaultValue: "\(alias.count)/\(MacAliasRules.maxLength)",
                    comment: "Character count for Mac alias field."
                ))
                .font(.system(size: 12))
                .foregroundColor(alias.count >= MacAliasRules.maxLength ? BrandColors.accentAmber : BrandColors.textMuted)
                .accessibilityHidden(true)
            }
        }
    }

    private var ctaBar: some View {
        VStack(spacing: 0) {
            Divider().background(BrandColors.border)
            Button(action: submit) {
                Text(LocalizedStringResource(
                    "macAlias.cta",
                    defaultValue: "Save",
                    comment: "CTA to save the chosen Mac alias."
                ))
                .font(OnboardingFonts.bodyBold)
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isValid ? BrandColors.accentGreen : BrandColors.border)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!isValid)
            .accessibilityIdentifier("macAlias.cta")
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(BrandColors.surfaceDeep)
    }

    private func submit() {
        switch PairedMacsStore.shared.setAlias(macID: mac.macID, alias: alias) {
        case .success:
            onNamed()
        case .duplicate:
            errorMessage = LocalizedStringResource(
                "macAlias.error.duplicate",
                defaultValue: "Another Mac in this home already uses this name. Pick a different one.",
                comment: "Error when the chosen Mac alias is already used by another paired Mac in the same household."
            )
        case .invalid(.empty):
            errorMessage = LocalizedStringResource(
                "macAlias.error.empty",
                defaultValue: "Pick a name with at least one character.",
                comment: "Error when the Mac alias field is empty or whitespace."
            )
        case .invalid(.tooLong):
            errorMessage = LocalizedStringResource(
                "macAlias.error.tooLong",
                defaultValue: "Names can be up to \(MacAliasRules.maxLength) characters.",
                comment: "Error when the Mac alias exceeds the maximum length."
            )
        case .invalid(.forbiddenCharacters):
            errorMessage = LocalizedStringResource(
                "macAlias.error.forbiddenCharacters",
                defaultValue: "Some characters are not allowed. Try removing punctuation like / : * ? \" < > |.",
                comment: "Error when the Mac alias contains forbidden characters."
            )
        case .unknownMac:
            // Defensive — the mac was removed underneath us. Dismiss to
            // get back to a consistent home state.
            onNamed()
        }
    }
}
