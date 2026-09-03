import SoyehtCore
import SwiftUI

/// The shape every neo onboarding screen shares: the canvas, one column of
/// content centred in the space above, and the actions pinned to the bottom
/// where a thumb reaches them.
///
/// Nothing here decides copy or spacing inside the column — a screen fills
/// `content` and `actions` and gets the same margins, the same back affordance
/// and the same palette as its neighbours, so the six screens read as one
/// flow rather than six drafts.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    private let palette: NeoPalette
    private let onBack: (() -> Void)?
    private let content: Content
    private let actions: Actions

    init(
        palette: NeoPalette = .cloud,
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.palette = palette
        self.onBack = onBack
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        ZStack {
            palette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(palette.textSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.Onboarding.back)
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "onboarding.back.a11y",
                            defaultValue: "Back",
                            comment: "VoiceOver label for the back chevron shared by the onboarding screens."
                        )))
                    }
                    Spacer()
                }
                .frame(height: 44)
                .padding(.horizontal, 8)

                Spacer(minLength: 12)

                content
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 24)

                actions
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .environment(\.neoPalette, palette)
    }
}
