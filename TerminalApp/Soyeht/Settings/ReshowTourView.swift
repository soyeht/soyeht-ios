import SwiftUI
import SoyehtCore

/// Settings > Sobre > Reapresentar tour (T088, FR-022).
/// Clears `CarouselSeenStorage` and triggers replay of `CarouselRootView`.
struct ReshowTourView: View {
    let onReshow: () -> Void

    var body: some View {
        Button(action: reshowTapped) {
            HStack {
                Label(
                    title: {
                        Text(LocalizedStringResource(
                            "settings.reshowTour.label",
                            defaultValue: "Reapresentar tour",
                            comment: "Settings entry to replay the onboarding carousel."
                        ))
                        .foregroundColor(BrandColors.textPrimary)
                    },
                    icon: {
                        Image(systemName: "play.circle")
                            .foregroundColor(BrandColors.accentGreen)
                    }
                )
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(BrandColors.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
    }

    private func reshowTapped() {
        CarouselSeenStorage().clearSeen()
        onReshow()
    }
}
