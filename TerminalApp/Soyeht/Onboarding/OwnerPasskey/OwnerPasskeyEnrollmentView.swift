#if os(iOS)
import SoyehtCore
import SwiftUI

/// "protect your home" — owner passkey first-enrollment screen (iOS).
///
/// A thin View over `OwnerPasskeyEnrollmentViewModel`: it renders `model.phase`
/// and NEVER inspects errors (no branch on the error type or its code). `onContinue`
/// runs on success — both `.fresh` and `.alreadyCommitted` (the recovered
/// committed-but-opaque case). `onSkip` runs when the owner chooses "set up
/// later" (first-class) or when the owner key is unavailable. Both advance
/// onboarding; nothing here blocks the user from reaching their home.
struct OwnerPasskeyEnrollmentView: View {
    let snapshot: SoyehtIdentitySnapshot
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var model: OwnerPasskeyEnrollmentViewModel?
    @State private var ownerKeyUnavailable = false
    private let anchorProvider = KeyWindowPasskeyAnchorProvider()

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()
            if let model {
                OwnerPasskeyEnrollmentContent(model: model, onContinue: onContinue, onSkip: onSkip)
            } else if ownerKeyUnavailable {
                OwnerPasskeyEnrollmentUnavailableContent(onContinue: onSkip)
            } else {
                ProgressView().tint(BrandColors.accentGreen)
            }
        }
        .task {
            guard model == nil, !ownerKeyUnavailable else { return }
            if let vm = await OwnerPasskeyEnrollmentComposer.makeViewModel(
                snapshot: snapshot,
                anchorProvider: anchorProvider
            ) {
                model = vm
            } else {
                ownerKeyUnavailable = true
            }
        }
    }
}

/// The interactive content, observing the view-model's `phase`. Kept separate so
/// the parent can build the view-model asynchronously (and degrade gracefully if
/// the owner key is missing) while this child observes `@Published phase`.
private struct OwnerPasskeyEnrollmentContent: View {
    @ObservedObject var model: OwnerPasskeyEnrollmentViewModel
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "faceid")
                    .font(.system(size: 56))
                    .foregroundColor(BrandColors.accentGreen)
                Text(LocalizedStringResource(
                    "ownerPasskey.enrollment.title",
                    defaultValue: "protect your home",
                    comment: "Headline for the optional owner passkey enrollment screen."
                ))
                    .font(OnboardingFonts.heading)
                    .foregroundColor(BrandColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(LocalizedStringResource(
                    "ownerPasskey.enrollment.subtitle",
                    defaultValue: "use Face ID to approve important changes — only you can.",
                    comment: "Subtitle explaining why the owner should set up a passkey."
                ))
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                Label {
                    Text(LocalizedStringResource(
                        "ownerPasskey.enrollment.privacy",
                        defaultValue: "your passkey stays on this device. nothing leaves it.",
                        comment: "Privacy reassurance on the owner passkey enrollment screen."
                    ))
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            footer
        }
        // The ONLY place phase drives navigation. Success (fresh or already
        // committed) continues; an explicit skip continues too. No error inspection.
        .onChange(of: model.phase) { phase in
            switch phase {
            case .completed:
                onContinue()
            case .skipped:
                onSkip()
            default:
                break
            }
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            Divider().background(BrandColors.border)
            if isFailed {
                // Uniform, generic hint — never derived from the underlying error.
                Text(LocalizedStringResource(
                    "ownerPasskey.enrollment.failure",
                    defaultValue: "couldn't set up. try again.",
                    comment: "Generic passkey enrollment failure message; intentionally does not expose the underlying reason."
                ))
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await model.enroll() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView().tint(BrandColors.buttonTextOnAccent)
                    } else {
                        Text(primaryTitle).font(OnboardingFonts.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(BrandColors.accentGreen)
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isWorking)

            Button {
                model.setUpLater()
            } label: {
                Text(LocalizedStringResource(
                    "ownerPasskey.enrollment.skip",
                    defaultValue: "set up later",
                    comment: "Skip button for optional owner passkey enrollment."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
            }
            .disabled(isWorking)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .background(BrandColors.surfaceDeep)
    }

    private var isWorking: Bool {
        if case .enrolling = model.phase { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private var primaryTitle: LocalizedStringResource {
        if isFailed {
            return LocalizedStringResource(
                "ownerPasskey.enrollment.retry",
                defaultValue: "try again",
                comment: "Retry button title for owner passkey enrollment."
            )
        }
        return LocalizedStringResource(
            "ownerPasskey.enrollment.continue",
            defaultValue: "continue",
            comment: "Primary button title to start owner passkey enrollment."
        )
    }
}

/// Shown when the owner key can't be loaded: passkey setup is unavailable here,
/// so we never block onboarding — the owner just continues and can enroll later.
private struct OwnerPasskeyEnrollmentUnavailableContent: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "faceid")
                    .font(.system(size: 56))
                    .foregroundColor(BrandColors.accentGreen)
                Text(LocalizedStringResource(
                    "ownerPasskey.enrollment.title",
                    defaultValue: "protect your home",
                    comment: "Headline for the optional owner passkey enrollment screen."
                ))
                    .font(OnboardingFonts.heading)
                    .foregroundColor(BrandColors.textPrimary)
                Text(LocalizedStringResource(
                    "ownerPasskey.enrollment.unavailable",
                    defaultValue: "you can set up a passkey later in settings.",
                    comment: "Message shown when passkey enrollment cannot be started because the owner key is unavailable."
                ))
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Divider().background(BrandColors.border)
                Button(action: onContinue) {
                    Text(LocalizedStringResource(
                        "ownerPasskey.enrollment.continue",
                        defaultValue: "continue",
                        comment: "Primary button title to start owner passkey enrollment."
                    ))
                        .font(OnboardingFonts.bodyBold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(BrandColors.accentGreen)
                        .foregroundColor(BrandColors.buttonTextOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .background(BrandColors.surfaceDeep)
        }
    }
}
#endif
