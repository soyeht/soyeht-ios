import SwiftUI

// MARK: - Claw Store View (Marketplace)

struct ClawStoreView: View {
    @StateObject private var viewModel: ClawStoreViewModel
    @Environment(\.dismiss) private var dismiss

    init(apiClient: SoyehtAPIClient = .shared) {
        _viewModel = StateObject(wrappedValue: ClawStoreViewModel(apiClient: apiClient))
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Text("<")
                                .font(SoyehtTheme.heading)
                                .foregroundColor(SoyehtTheme.historyGreen)
                        }
                        Text("claw store")
                            .font(SoyehtTheme.pageTitle)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }
                    Text("ai assistant marketplace")
                        .font(SoyehtTheme.cardBody)
                        .foregroundColor(SoyehtTheme.textComment)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

                if viewModel.isLoading {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView().tint(SoyehtTheme.historyGreen)
                            Text("loading claws...")
                                .font(SoyehtTheme.smallMono)
                                .foregroundColor(SoyehtTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .accessibilityIdentifier(AccessibilityID.ClawStore.loadingState)
                    Spacer()
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Text("[!] \(error)")
                                .font(SoyehtTheme.smallMono)
                                .foregroundColor(SoyehtTheme.textWarning)
                                .multilineTextAlignment(.center)
                            Button("retry") { Task { await viewModel.loadClaws() } }
                                .font(SoyehtTheme.labelFont)
                                .foregroundColor(SoyehtTheme.historyGreen)
                        }
                        .padding(.horizontal, 20)
                        Spacer()
                    }
                    .accessibilityIdentifier(AccessibilityID.ClawStore.errorState)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Editor's Pick
                            if let featured = viewModel.featuredClaw {
                                Text("// editor's pick")
                                    .font(SoyehtTheme.sectionLabel)
                                    .foregroundColor(SoyehtTheme.historyGreen)

                                NavigationLink(value: ClawRoute.detail(featured)) {
                                    FeaturedClawCardContent(
                                        claw: featured,
                                        onInstall: { Task { await viewModel.installClaw(featured) } }
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            // Trending
                            if !viewModel.trendingClaws.isEmpty {
                                Text("// trending")
                                    .font(SoyehtTheme.sectionLabel)
                                    .foregroundColor(SoyehtTheme.textComment)

                                HStack(spacing: 10) {
                                    ForEach(viewModel.trendingClaws) { claw in
                                        clawCard(claw)
                                    }
                                }
                            }

                            // Community reviews section
                            if let featured = viewModel.featuredClaw {
                                let reviews = ClawMockData.reviews(for: featured.name)
                                if !reviews.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("// community says")
                                            .font(SoyehtTheme.sectionLabel)
                                            .foregroundColor(SoyehtTheme.textComment)

                                        HStack(spacing: 8) {
                                            ForEach(Array(reviews.prefix(2).enumerated()), id: \.offset) { _, review in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("\"\(review.text)\"")
                                                        .font(SoyehtTheme.microMono)
                                                        .italic()
                                                        .foregroundColor(SoyehtTheme.textPrimary)
                                                        .lineLimit(3)
                                                    Text("— \(review.author)")
                                                        .font(SoyehtTheme.microMono)
                                                        .foregroundColor(SoyehtTheme.textComment)
                                                }
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(hex: "#0A0A0A"))
                                                .overlay(
                                                    Rectangle().stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            // More Claws
                            if !viewModel.moreClaws.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("// more claws")
                                        .font(SoyehtTheme.sectionLabel)
                                        .foregroundColor(SoyehtTheme.textComment)

                                    let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                                    LazyVGrid(columns: columns, spacing: 10) {
                                        ForEach(viewModel.moreClaws) { claw in
                                            clawCard(claw)
                                        }
                                    }
                                }
                            }

                            // Footer
                            Text("\(viewModel.availableCount) claws available // \(viewModel.installedCount) installed")
                                .font(SoyehtTheme.tagFont)
                                .foregroundColor(SoyehtTheme.textComment)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            await viewModel.loadClaws()
        }
        .alert("error", isPresented: .init(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button("ok") { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }

    // MARK: - Claw Card with install action

    @ViewBuilder
    private func clawCard(_ claw: Claw) -> some View {
        NavigationLink(value: ClawRoute.detail(claw)) {
            ClawCardView(
                claw: claw,
                showInstallButton: true,
                onInstall: { Task { await viewModel.installClaw(claw) } }
            )
        }
        .buttonStyle(.plain)
    }
}
