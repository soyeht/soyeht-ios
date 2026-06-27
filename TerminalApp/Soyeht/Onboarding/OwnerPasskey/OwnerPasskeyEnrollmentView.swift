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
            if let vm = OwnerPasskeyEnrollmentComposer.makeViewModel(
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
                Text("protect your home")
                    .font(OnboardingFonts.heading)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text("use Face ID to approve important changes — only you can.")
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Label("your passkey stays on this device. nothing leaves it.", systemImage: "lock.fill")
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(.white.opacity(0.5))
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
                Text("couldn't set up. try again.")
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await model.enroll() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView().tint(.black)
                    } else {
                        Text(primaryTitle).font(OnboardingFonts.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(BrandColors.accentGreen)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isWorking)

            Button("set up later") { model.setUpLater() }
                .font(OnboardingFonts.subheadline)
                .foregroundColor(.white.opacity(0.6))
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

    private var primaryTitle: String {
        isFailed ? "try again" : "continue"
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
                Text("protect your home")
                    .font(OnboardingFonts.heading)
                    .foregroundColor(.white)
                Text("you can set up a passkey later in settings.")
                    .font(OnboardingFonts.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Divider().background(BrandColors.border)
                Button(action: onContinue) {
                    Text("continue")
                        .font(OnboardingFonts.bodyBold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(BrandColors.accentGreen)
                        .foregroundColor(.black)
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
