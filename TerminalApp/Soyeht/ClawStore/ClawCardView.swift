import SwiftUI
import SoyehtCore

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
                    .font(Typography.monoCardTitle)
                    .foregroundColor(SoyehtTheme.textPrimary)

                Spacer()

                Text(claw.language.capitalized)
                    .font(Typography.monoMicroBold)
                    .foregroundColor(SoyehtTheme.historyGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SoyehtTheme.historyGreenBg)
            }

            // Meta: rating + installs
            if info.rating > 0 {
                Text(verbatim: "\(info.ratingStars) \(String(format: "%.1f", info.rating)) \u{00B7} \(info.installCount)")
                    .font(Typography.monoMicro)
                    .foregroundColor(SoyehtTheme.textComment)
            }

            // Description (from API)
            Text(claw.description)
                .font(Typography.monoSmall)
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
                                    Text(verbatim: "\(progress.downloadedMB) / \(progress.totalMB) MB")
                                        .font(Typography.monoMicro)
                                        .foregroundColor(SoyehtTheme.textSecondary)
                                }
                                Spacer()
                                Text(verbatim: "\(progress.percent)%")
                                    .font(Typography.monoMicro)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                    .accessibilityIdentifier(AccessibilityID.ClawStore.clawCardProgressPercent(claw.name))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                    } else {
                        // First tick before progress payload arrives — short text, no spinner.
                        Text("claw.card.state.installing")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.historyGreen)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                    }

                case .uninstalling:
                    HStack(spacing: 6) {
                        Spacer()
                        ProgressView().tint(SoyehtTheme.accentAmber).scaleEffect(0.7)
                        Text("claw.card.state.uninstalling")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.accentAmber)
                        Spacer()
                    }
                    .frame(height: 32)

                case .installed:
                    Text("claw.card.state.installed")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))

                case .installedButBlocked:
                    // Installed but something is preventing creation. Distinct amber
                    // badge — user taps into detail to see the reasons block and uninstall.
                    Text("claw.card.state.installedBlocked")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.accentAmber)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .overlay(Rectangle().stroke(SoyehtTheme.accentAmber, lineWidth: 1))

                case .installFailed:
                    Button(action: { onInstall?() }) {
                        Text("claw.card.action.retry")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.accentRed)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .overlay(Rectangle().stroke(SoyehtTheme.accentRed, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                case .notInstalled:
                    Button(action: { onInstall?() }) {
                        Text("claw.card.action.install")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.historyGreen)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                case .unknown:
                    Text("claw.card.state.unknown")
                        .font(Typography.monoTag)
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
                    .font(Typography.monoHeading)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Spacer()
                Text(claw.displayVersion)
                    .font(Typography.monoMicroBold)
                    .foregroundColor(SoyehtTheme.historyGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SoyehtTheme.historyGreenBg)
            }

            // Meta row: language (API) + rating (mock) + installs (mock)
            HStack(spacing: 12) {
                Text(claw.language.capitalized)
                    .font(Typography.monoMicroBold)
                    .foregroundColor(SoyehtTheme.historyGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SoyehtTheme.historyGreenBg)

                if info.rating > 0 {
                    Text(verbatim: "\(info.ratingStars) \(String(format: "%.1f", info.rating))")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Text(LocalizedStringResource(
                        "claw.featured.installsCount",
                        defaultValue: "\(info.installCount) installs",
                        comment: "Meta row — total install count. %lld = count."
                    ))
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textComment)
                }
            }

            // Description (from API)
            Text(claw.description)
                .font(Typography.monoCardBody)
                .foregroundColor(SoyehtTheme.textPrimary)

            // Featured review (mock)
            if let review = reviews.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\"\(review.text)\"")
                        .font(Typography.monoSmall)
                        .italic()
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .lineLimit(2)
                    Text(verbatim: "— \(review.author)")
                        .font(Typography.monoMicro)
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
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                            }
                            Spacer()
                            Text("\(progress.percent)%")
                                .font(Typography.monoTag)
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
                        Text("claw.card.state.installing")
                            .font(Typography.monoBodyBold)
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
                        .font(Typography.monoBodyBold)
                        .foregroundColor(SoyehtTheme.accentAmber)
                    Spacer()
                }
                .frame(height: 40)

            case .installed:
                HStack {
                    Spacer()
                    Text("claw.featured.action.selected")
                        .font(Typography.monoBodyBold)
                        .foregroundColor(.black)
                    Spacer()
                }
                .frame(height: 40)
                .background(SoyehtTheme.historyGreen)

            case .installedButBlocked:
                HStack {
                    Spacer()
                    Text("claw.card.state.installedBlocked")
                        .font(Typography.monoBodyBold)
                        .foregroundColor(SoyehtTheme.accentAmber)
                    Spacer()
                }
                .frame(height: 40)
                .overlay(Rectangle().stroke(SoyehtTheme.accentAmber, lineWidth: 1))

            case .installFailed:
                Button(action: { onInstall?() }) {
                    Text("claw.featured.action.retryInstall")
                        .font(Typography.monoBodyBold)
                        .foregroundColor(SoyehtTheme.accentRed)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .overlay(Rectangle().stroke(SoyehtTheme.accentRed, lineWidth: 1))
                }
                .buttonStyle(.plain)

            case .notInstalled:
                Button(action: { onInstall?() }) {
                    Text("claw.card.action.install")
                        .font(Typography.monoBodyBold)
                        .foregroundColor(SoyehtTheme.historyGreen)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .overlay(Rectangle().stroke(SoyehtTheme.historyGreen, lineWidth: 1))
                }
                .buttonStyle(.plain)

            case .unknown:
                Text("claw.featured.state.unknownRefresh")
                    .font(Typography.monoBodyBold)
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
