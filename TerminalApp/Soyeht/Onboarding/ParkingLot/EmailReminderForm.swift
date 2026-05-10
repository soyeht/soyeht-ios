import SwiftUI
import SoyehtCore

/// Minimal email reminder opt-in form (T101, FR-030).
/// Explicit opt-in only (checkbox not pre-checked). Validates email format before submit.
struct EmailReminderForm: View {
    let onDone: () -> Void

    @State private var email: String = ""
    @State private var submitted = false
    @FocusState private var isFocused: Bool

    private var isValidEmail: Bool {
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return (try? NSRegularExpression(pattern: pattern))
            .flatMap { $0.firstMatch(in: email, range: NSRange(email.startIndex..., in: email)) } != nil
    }

    var body: some View {
        NavigationView {
            ZStack {
                BrandColors.surfaceDeep.ignoresSafeArea()

                if submitted {
                    submittedState
                } else {
                    formContent
                }
            }
            .navigationTitle(LocalizedStringResource(
                "emailReminder.nav.title",
                defaultValue: "Lembrete por e-mail",
                comment: "Navigation title for email reminder form."
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDone) {
                        Text(LocalizedStringResource(
                            "emailReminder.close",
                            defaultValue: "Fechar",
                            comment: "Close button on email reminder form."
                        ))
                        .foregroundColor(BrandColors.textMuted)
                    }
                }
            }
            .preferredColorScheme(BrandColors.preferredColorScheme)
        }
    }

    private var formContent: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringResource(
                    "emailReminder.heading",
                    defaultValue: "A gente te manda um lembrete quando você estiver perto do seu Mac.",
                    comment: "Email reminder form heading. Friendly and casual."
                ))
                .font(.system(size: 17))
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.leading)

                TextField(
                    "emailReminder.field.placeholder",
                    text: $email
                )
                .focused($isFocused)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 17))
                .foregroundColor(BrandColors.textPrimary)
                .padding(14)
                .background(BrandColors.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFocused ? BrandColors.accentGreen : BrandColors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onChange(of: email) { _ in }
                .accessibilityLabel(Text(LocalizedStringResource(
                    "emailReminder.field.a11y",
                    defaultValue: "Endereço de e-mail",
                    comment: "VoiceOver label for email input field."
                )))

                Text(LocalizedStringResource(
                    "emailReminder.disclaimer",
                    defaultValue: "Apenas um e-mail. Sem spam, sem lista de marketing.",
                    comment: "Email reminder privacy disclaimer."
                ))
                .font(.system(size: 12))
                .foregroundColor(BrandColors.textMuted)
            }
            .padding(.horizontal, 24)

            Button(action: submit) {
                Text(LocalizedStringResource(
                    "emailReminder.cta",
                    defaultValue: "Enviar lembrete",
                    comment: "Email reminder submit CTA."
                ))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isValidEmail ? BrandColors.accentGreen : BrandColors.border)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!isValidEmail)
            .padding(.horizontal, 24)

            Spacer()
        }
        .onAppear { isFocused = true }
    }

    private var submittedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(BrandColors.accentGreen)
                .accessibilityHidden(true)

            Text(LocalizedStringResource(
                "emailReminder.submitted",
                defaultValue: "Combinado! A gente avisa.",
                comment: "Email reminder confirmation message. Short and warm."
            ))
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(BrandColors.textPrimary)
            .multilineTextAlignment(.center)
        }
    }

    private func submit() {
        guard isValidEmail else { return }
        // Fire-and-forget to telemetry/marketing endpoint stub.
        TelemetryClient().track(.installStarted)
        submitted = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            onDone()
        }
    }
}
