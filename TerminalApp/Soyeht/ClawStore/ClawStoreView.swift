import SwiftUI
import SoyehtCore

// MARK: - Claw Store View (Marketplace)

struct ClawStoreView: View {
    @StateObject private var viewModel: ClawStoreViewModel
    let context: ServerContext
    @Environment(\.dismiss) private var dismiss

    init(context: ServerContext) {
        self.context = context
        _viewModel = StateObject(wrappedValue: ClawStoreViewModel(context: context))
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Text(verbatim: "<")
                                .font(Typography.monoPageTitle)
                                .foregroundColor(SoyehtTheme.accentGreen)
                        }
                        Text("clawstore.title")
                            .font(Typography.monoPageTitle)
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }
                    Text("clawstore.subtitle")
                        .font(Typography.monoCardBody)
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
                            Text("clawstore.loading")
                                .font(Typography.monoSmall)
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
                            Text(LocalizedStringResource(
                                "clawstore.error.banner",
                                defaultValue: "[!] \(error)",
                                comment: "Error banner. %@ = error message."
                            ))
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textWarning)
                                .multilineTextAlignment(.center)
                            Button("clawstore.action.retry") { Task { await viewModel.loadClaws() } }
                                .font(Typography.monoLabel)
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
                                Text("clawstore.section.editorsPick")
                                    .font(Typography.monoSectionLabel)
                                    .foregroundColor(SoyehtTheme.historyGreen)

                                NavigationLink(value: ClawRoute.detail(featured, serverId: context.serverId)) {
                                    FeaturedClawCardContent(
                                        claw: featured,
                                        onInstall: { Task { await viewModel.installClaw(featured) } }
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            // Trending
                            if !viewModel.trendingClaws.isEmpty {
                                Text("clawstore.section.trending")
                                    .font(Typography.monoSectionLabel)
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
                                        Text("clawstore.section.communitySays")
                                            .font(Typography.monoSectionLabel)
                                            .foregroundColor(SoyehtTheme.textComment)

                                        HStack(spacing: 8) {
                                            ForEach(Array(reviews.prefix(2).enumerated()), id: \.offset) { _, review in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(verbatim: "\"\(review.text)\"")
                                                        .font(Typography.monoMicro)
                                                        .italic()
                                                        .foregroundColor(SoyehtTheme.textPrimary)
                                                        .lineLimit(3)
                                                    Text(verbatim: "— \(review.author)")
                                                        .font(Typography.monoMicro)
                                                        .foregroundColor(SoyehtTheme.textComment)
                                                }
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(SoyehtTheme.bgPrimary)
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
                                    Text("clawstore.section.moreClaws")
                                        .font(Typography.monoSectionLabel)
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
                            Text(LocalizedStringResource(
                                "clawstore.footer.summary",
                                defaultValue: "\(viewModel.availableCount) claws available // \(viewModel.installedCount) installed",
                                comment: "Footer summary. %1$lld = available, %2$lld = installed."
                            ))
                                .font(Typography.monoTag)
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
        .alert("common.alert.error.title.lower", isPresented: .init(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button("common.button.ok.lower") { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }

    // MARK: - Claw Card with install action

    @ViewBuilder
    private func clawCard(_ claw: Claw) -> some View {
        NavigationLink(value: ClawRoute.detail(claw, serverId: context.serverId)) {
            ClawCardView(
                claw: claw,
                showInstallButton: true,
                onInstall: { Task { await viewModel.installClaw(claw) } }
            )
        }
        .buttonStyle(.plain)
    }
}
