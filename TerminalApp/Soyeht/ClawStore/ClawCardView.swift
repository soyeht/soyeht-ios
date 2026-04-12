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
                switch claw.installState {
                case .installing(let progress):
                    if let progress {
                        VStack(spacing: 4) {
                            ProgressView(value: progress.fraction)
                                .tint(SoyehtTheme.historyGreen)
                                .scaleEffect(x: 1, y: 1.5, anchor: .center)
                                .accessibilityIdentifier(AccessibilityID.ClawStore.clawCardProgressBar(claw.name))
                            HStack {
                                if progress.hasBytes {
                                    Text("\(progress.downloadedMB) / \(progress.totalMB) MB")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(SoyehtTheme.textSecondary)
                                }
                                Spacer()
                                Text("\(progress.percent)%")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                    .accessibilityIdentifier(AccessibilityID.ClawStore.clawCardProgressPercent(claw.name))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                    } else {
                        // First tick before progress payload arrives — short text, no spinner.
                        Text("installing...")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.historyGreen)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                    }

                case .uninstalling:
                    HStack(spacing: 6) {
                        Spacer()
                        ProgressView().tint(SoyehtTheme.accentAmber).scaleEffect(0.7)
                        Text("uninstalling...")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.accentAmber)
                        Spacer()
                    }
                    .frame(height: 32)

                case .installed:
                    Text("installed")
                        .font(SoyehtTheme.tagFont)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))

                case .installedButBlocked:
                    // Installed but something is preventing creation. Distinct amber
                    // badge — user taps into detail to see the reasons block and uninstall.
                    Text("installed \u{2022} blocked")
                        .font(SoyehtTheme.tagFont)
                        .foregroundColor(SoyehtTheme.accentAmber)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .overlay(Rectangle().stroke(SoyehtTheme.accentAmber, lineWidth: 1))

                case .installFailed:
                    Button(action: { onInstall?() }) {
                        Text("retry")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.accentRed)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .overlay(Rectangle().stroke(SoyehtTheme.accentRed, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                case .notInstalled:
                    Button(action: { onInstall?() }) {
                        Text("install")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.historyGreen)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                case .unknown:
                    Text("unknown")
                        .font(SoyehtTheme.tagFont)
                        .foregroundColor(SoyehtTheme.textComment)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .overlay(Rectangle().stroke(SoyehtTheme.textComment, lineWidth: 1))
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

            // Install/Selected button — driven entirely by installState.
            switch claw.installState {
            case .installing(let progress):
                if let progress {
                    VStack(spacing: 6) {
                        ProgressView(value: progress.fraction)
                            .tint(SoyehtTheme.historyGreen)
                            .accessibilityIdentifier(AccessibilityID.ClawStore.clawCardProgressBar(claw.name))
                        HStack {
                            if progress.hasBytes {
                                Text("\(progress.downloadedMB) / \(progress.totalMB) MB")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(SoyehtTheme.textSecondary)
                            }
                            Spacer()
                            Text("\(progress.percent)%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(SoyehtTheme.textSecondary)
                                .accessibilityIdentifier(AccessibilityID.ClawStore.clawCardProgressPercent(claw.name))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                } else {
                    HStack(spacing: 8) {
                        Spacer()
                        ProgressView().tint(SoyehtTheme.historyGreen)
                        Text("installing...")
                            .font(SoyehtTheme.bodyBold)
                            .foregroundColor(SoyehtTheme.historyGreen)
                        Spacer()
                    }
                    .frame(height: 40)
                }

            case .uninstalling:
                HStack(spacing: 8) {
                    Spacer()
                    ProgressView().tint(SoyehtTheme.accentAmber)
                    Text("uninstalling...")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(SoyehtTheme.accentAmber)
                    Spacer()
                }
                .frame(height: 40)

            case .installed:
                HStack {
                    Spacer()
                    Text("selected >")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(.black)
                    Spacer()
                }
                .frame(height: 40)
                .background(SoyehtTheme.historyGreen)

            case .installedButBlocked:
                HStack {
                    Spacer()
                    Text("installed \u{2022} blocked")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(SoyehtTheme.accentAmber)
                    Spacer()
                }
                .frame(height: 40)
                .overlay(Rectangle().stroke(SoyehtTheme.accentAmber, lineWidth: 1))

            case .installFailed:
                Button(action: { onInstall?() }) {
                    Text("retry install")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(SoyehtTheme.accentRed)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .overlay(Rectangle().stroke(SoyehtTheme.accentRed, lineWidth: 1))
                }
                .buttonStyle(.plain)

            case .notInstalled:
                Button(action: { onInstall?() }) {
                    Text("install")
                        .font(SoyehtTheme.bodyBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
                }
                .buttonStyle(.plain)

            case .unknown:
                Text("unknown state — refresh")
                    .font(SoyehtTheme.bodyBold)
                    .foregroundColor(SoyehtTheme.accentAmber)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .overlay(Rectangle().stroke(SoyehtTheme.accentAmber, lineWidth: 1))
            }
        }
        .padding(20)
        .background(Color(hex: "#0A0A0A"))
        .overlay(
            Rectangle()
                .stroke(claw.installState.isInstalled ? SoyehtTheme.historyGreen : SoyehtTheme.bgCardBorder, lineWidth: 1)
        )
    }
}
