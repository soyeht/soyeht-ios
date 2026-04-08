import SwiftUI

// MARK: - Claw Card (Reusable in Hub + Store)

struct ClawCardView: View {
    let claw: Claw
    let showInstallButton: Bool
    var onInstall: (() -> Void)?

    private var info: ClawMockData.ClawStoreInfo {
        ClawMockData.storeInfo(for: claw.name)
    }

    var body: some View {
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
                if claw.isInstalling {
                    HStack(spacing: 6) {
                        Spacer()
                        ProgressView().tint(SoyehtTheme.historyGreen).scaleEffect(0.7)
                        Text("installing...")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.historyGreen)
                        Spacer()
                    }
                    .frame(height: 32)
                } else if claw.installed {
                    Text("selected")
                        .font(SoyehtTheme.tagFont)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .overlay(
                            Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                        )
                } else {
                    Button(action: { onInstall?() }) {
                        Text(claw.isFailed ? "retry" : "install")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.historyGreen)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .overlay(
                                Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color(hex: "#0A0A0A"))
        .overlay(
            Rectangle()
                .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
        )
        .accessibilityIdentifier(AccessibilityID.ClawStore.clawCard(claw.name))
    }
}

// MARK: - Featured Claw Card Content (no Button wrapper — use inside NavigationLink)

struct FeaturedClawCardContent: View {
    let claw: Claw
    var onInstall: (() -> Void)?

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
                Text(claw.displayVersion)
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

            // Install/Selected button
            if claw.isInstalling {
                HStack(spacing: 8) {
                    Spacer()
                    ProgressView().tint(SoyehtTheme.historyGreen)
                    Text("installing...")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                    Spacer()
                }
                .frame(height: 40)
            } else if claw.installed {
                HStack {
                    Spacer()
                    Text("selected >")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(.black)
                    Spacer()
                }
                .frame(height: 40)
                .background(SoyehtTheme.historyGreen)
            } else {
                Button(action: { onInstall?() }) {
                    Text(claw.isFailed ? "retry install" : "install")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .overlay(
                            Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(Color(hex: "#0A0A0A"))
        .overlay(
            Rectangle()
                .stroke(claw.installed ? SoyehtTheme.historyGreen : SoyehtTheme.bgCardBorder, lineWidth: 1)
        )
    }
}
