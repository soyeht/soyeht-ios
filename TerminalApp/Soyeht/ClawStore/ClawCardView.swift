import SwiftUI

// MARK: - Claw Card (Reusable in Hub + Store)

struct ClawCardView: View {
    let claw: Claw
    let showInstallButton: Bool
    let onTap: () -> Void

    init(claw: Claw, showInstallButton: Bool = false, onTap: @escaping () -> Void) {
        self.claw = claw
        self.showInstallButton = showInstallButton
        self.onTap = onTap
    }

    private var info: ClawMockData.ClawStoreInfo {
        ClawMockData.storeInfo(for: claw.name)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Top row: name + language badge
                HStack {
                    Text(claw.name)
                        .font(SoyehtTheme.cardTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()

                    Text(claw.language.capitalized)
                        .font(SoyehtTheme.microBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoyehtTheme.historyGreenBg)
                }

                // Meta: rating + installs
                if info.rating > 0 {
                    Text("\(info.ratingStars) \(String(format: "%.1f", info.rating)) \u{00B7} \(info.installCount)")
                        .font(SoyehtTheme.microMono)
                        .foregroundColor(SoyehtTheme.textComment)
                }

                // Description (from API)
                Text(claw.description)
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textComment)
                    .lineLimit(2)

                if showInstallButton {
                    HStack {
                        Spacer()
                        Text(claw.installed ? "selected" : "install")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.historyGreen)
                        Spacer()
                    }
                    .frame(height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                    )
                }
            }
            .padding(12)
            .background(Color(hex: "#0A0A0A"))
            .overlay(
                Rectangle()
                    .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Featured Claw Card Content (no Button wrapper — use inside NavigationLink)

struct FeaturedClawCardContent: View {
    let claw: Claw

    private var info: ClawMockData.ClawStoreInfo {
        ClawMockData.storeInfo(for: claw.name)
    }

    private var reviews: [ClawMockData.ClawReview] {
        ClawMockData.reviews(for: claw.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                // Top: name + version badge
                HStack {
                    Text(claw.name)
                        .font(SoyehtTheme.heading)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Spacer()
                    Text(ClawMockData.detailSpecs(for: claw.name).version)
                        .font(SoyehtTheme.microBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SoyehtTheme.historyGreenBg)
                }

                // Meta row: language (API) + rating (mock) + installs (mock)
                HStack(spacing: 12) {
                    Text(claw.language.capitalized)
                        .font(SoyehtTheme.microBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoyehtTheme.historyGreenBg)

                    if info.rating > 0 {
                        Text("\(info.ratingStars) \(String(format: "%.1f", info.rating))")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.textPrimary)

                        Text("\(info.installCount) installs")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.textComment)
                    }
                }

                // Description (from API)
                Text(claw.description)
                    .font(SoyehtTheme.cardBody)
                    .foregroundColor(SoyehtTheme.textPrimary)

                // Featured review (mock)
                if let review = reviews.first {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\"\(review.text)\"")
                            .font(SoyehtTheme.smallMono)
                            .italic()
                            .foregroundColor(SoyehtTheme.textPrimary)
                            .lineLimit(2)
                        Text("— \(review.author)")
                            .font(SoyehtTheme.microMono)
                            .foregroundColor(SoyehtTheme.textComment)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SoyehtTheme.bgSecondary)
                }

                // Selected/Install button
                HStack {
                    Spacer()
                    Text(claw.installed ? "selected >" : "install")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(claw.installed ? .black : SoyehtTheme.historyGreen)
                    Spacer()
                }
                .frame(height: 40)
                .background(claw.installed ? SoyehtTheme.historyGreen : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(SoyehtTheme.historyGreen, lineWidth: claw.installed ? 0 : 1)
                )
            }
            .padding(20)
            .background(Color(hex: "#0A0A0A"))
            .overlay(
                Rectangle()
                    .stroke(claw.installed ? SoyehtTheme.historyGreen : SoyehtTheme.bgCardBorder, lineWidth: 1)
            )
    }
}
