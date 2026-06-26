import SwiftUI
import SoyehtCore

// MARK: - Claw Store View (Marketplace)

struct ClawStoreView: View {
    let installTarget: ClawInstallTarget
    let resolution: ClawInstallTargetResolver.Resolution
    @Environment(\.dismiss) private var dismiss

    /// PR-3 init. iOS Claw Store always speaks `ClawInstallTarget` —
    /// the resolver decides the wire path. The list of `ClawAPITarget`
    /// values funnels through here so the `.householdStore`/
    /// `.householdDetail` route ramps don't appear in any iOS call site.
    init(installTarget: ClawInstallTarget) {
        self.installTarget = installTarget
        let resolution = ClawInstallTargetResolver.resolve(installTarget)
        self.resolution = resolution
    }

    var body: some View {
        switch resolution {
        case .unavailable:
            MacClawUnavailableView(serverDisplayName: serverDisplayName, onBack: { dismiss() })
        case .server, .householdEndpoint:
            ResolvedClawStoreView(installTarget: installTarget, resolution: resolution)
        }
    }

    private var serverDisplayName: String? {
        ServerRegistry.shared.server(id: installTarget.serverID)?.displayName
    }
}

private struct ResolvedClawStoreView: View {
    @StateObject private var viewModel: ClawStoreViewModel
    @StateObject private var readinessObserver: GuestImageReadinessObserver
    let installTarget: ClawInstallTarget
    let resolution: ClawInstallTargetResolver.Resolution
    @Environment(\.dismiss) private var dismiss

    init(installTarget: ClawInstallTarget, resolution: ClawInstallTargetResolver.Resolution) {
        self.installTarget = installTarget
        self.resolution = resolution
        // E2d-4: pass the canonical `ClawMachineTarget` (`resolution`) directly —
        // it carries the serverID; `resolution.apiTarget` is the lossy wire form.
        // The view model preconditions on `.unavailable`.
        _viewModel = StateObject(wrappedValue: ClawStoreViewModel(machineTarget: resolution))
        _readinessObserver = StateObject(wrappedValue: GuestImageReadinessObserver(
            initialState: GuestImageReadinessClient.initialState(
                for: installTarget,
                resolution: resolution
            )
        ))
    }

    var body: some View {
        catalogBody
    }

    @ViewBuilder
    private var catalogBody: some View {
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

                    if !readinessObserver.state.allowsInstall {
                        readinessBanner
                    }
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

                                NavigationLink(value: detailRoute(for: featured)) {
                                    FeaturedClawCardContent(
                                        claw: featured,
                                        showInstallButton: readinessObserver.state.allowsInstall,
                                        onInstall: { installIfReady(featured) }
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
            readinessObserver.start(target: installTarget, resolution: resolution)
            await viewModel.loadClaws()
        }
        .onDisappear {
            readinessObserver.stop()
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
        NavigationLink(value: detailRoute(for: claw)) {
            ClawCardView(
                claw: claw,
                showInstallButton: readinessObserver.state.allowsInstall,
                onInstall: { installIfReady(claw) }
            )
        }
        .buttonStyle(.plain)
    }

    private func installIfReady(_ claw: Claw) {
        // Backend installability (theyos #88) is the authoritative gate; the
        // card already hides the CTA, this is the matching action-side guard.
        guard claw.installability.isInstallable else { return }
        guard readinessObserver.state.allowsInstall else { return }
        Task { await viewModel.installClaw(claw) }
    }

    @ViewBuilder
    private var readinessBanner: some View {
        switch readinessObserver.state {
        case .allowed:
            EmptyView()
        case .checking:
            banner(
                title: LocalizedStringResource(
                    "clawstore.guestImage.checking.title",
                    defaultValue: "Checking this Mac",
                    comment: "Catalog banner title while iPhone checks whether a Mac can install Claws."
                ),
                body: LocalizedStringResource(
                    "clawstore.guestImage.checking.body",
                    defaultValue: "Install actions will appear when this Mac reports that it is ready.",
                    comment: "Catalog banner body while iPhone checks whether a Mac can install Claws."
                ),
                color: SoyehtTheme.accentAmber,
                showsSpinner: true
            )
        case .unavailable:
            banner(
                title: LocalizedStringResource(
                    "clawstore.guestImage.unavailable.title",
                    defaultValue: "Cannot check this Mac yet",
                    comment: "Catalog banner title when iPhone cannot reach Mac bootstrap status."
                ),
                body: LocalizedStringResource(
                    "clawstore.guestImage.unavailable.body",
                    defaultValue: "You can browse Claws here. Open Soyeht on the Mac before installing.",
                    comment: "Catalog banner body when iPhone cannot reach Mac bootstrap status."
                ),
                color: SoyehtTheme.accentAmber,
                showsSpinner: false
            )
        case .blocked(let readiness):
            switch readiness {
            case .notStarted:
                banner(
                    title: LocalizedStringResource(
                        "clawstore.guestImage.notStarted.title",
                        defaultValue: "Setup required on this Mac",
                        comment: "Catalog banner title when Mac guest image setup has not started."
                    ),
                    body: LocalizedStringResource(
                        "clawstore.guestImage.notStarted.body",
                        defaultValue: "Browse is available. Start preparation from this iPhone, then install when the Mac is ready.",
                        comment: "Catalog banner body when Mac guest image setup has not started."
                    ),
                    color: SoyehtTheme.accentAmber,
                    showsSpinner: false,
                    actionTitle: LocalizedStringResource(
                        "clawstore.guestImage.prepare.button",
                        defaultValue: "Prepare this Mac",
                        comment: "Button that starts remote guest-image preparation from the Claw Store catalog."
                    ),
                    action: { startGuestImagePreparation(force: false) }
                )
            case .inProgress:
                banner(
                    title: LocalizedStringResource(
                        "clawstore.guestImage.inProgress.title",
                        defaultValue: "Preparing this Mac",
                        comment: "Catalog banner title while Mac guest image setup is in progress."
                    ),
                    body: LocalizedStringResource(
                        "clawstore.guestImage.inProgress.body",
                        defaultValue: "Browse is available. Install will unlock when preparation finishes.",
                        comment: "Catalog banner body while Mac guest image setup is in progress."
                    ),
                    color: SoyehtTheme.accentAmber,
                    showsSpinner: true
                )
            case .failed(let error, let code):
                // Reason-coded banner: copy from GuestImageFailureCopy; CTA/action
                // from the shared policy. Raw `error` stays behind Details.
                if let presentation = GuestImageRecoveryPolicy.presentation(for: readiness) {
                    banner(
                        title: GuestImageFailureCopy.title(for: code),
                        body: GuestImageFailureCopy.body(for: code),
                        color: SoyehtTheme.accentRed,
                        showsSpinner: false,
                        detail: error,
                        actionTitle: GuestImageFailureCopy.primaryLabel(for: presentation.cta),
                        action: guestImageRecoveryHandler(for: presentation.cta)
                    )
                }
            case .notApplicable, .ready:
                EmptyView()
            }
        }
    }

    private func banner(
        title: LocalizedStringResource,
        body: LocalizedStringResource,
        color: Color,
        showsSpinner: Bool,
        detail: String? = nil,
        actionTitle: LocalizedStringResource? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showsSpinner {
                    ProgressView()
                        .tint(color)
                        .scaleEffect(0.65)
                }
                Text(title)
                    .font(Typography.monoTag)
                    .foregroundColor(color)
            }
            Text(body)
                .font(Typography.monoMicro)
                .foregroundColor(SoyehtTheme.textComment)
                .fixedSize(horizontal: false, vertical: true)

            // Raw engine text behind a discreet "Details" disclosure — never primary.
            if let rawDetail = GuestImageFailureCopy.combinedRawDetail(detail: detail, prepareError: readinessObserver.prepareError) {
                DisclosureGroup {
                    Text(verbatim: rawDetail)
                        .font(Typography.monoMicro)
                        .foregroundColor(SoyehtTheme.textComment)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(LocalizedStringResource(
                        "clawstore.guestImage.details.disclosure",
                        defaultValue: "Details",
                        comment: "Disclosure toggle revealing the raw engine error as secondary detail in the catalog banner."
                    ))
                    .font(Typography.monoMicro)
                    .foregroundColor(SoyehtTheme.textComment)
                }
                .tint(SoyehtTheme.textComment)
                .accessibilityIdentifier(AccessibilityID.ClawStore.guestImageDetailsDisclosure)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if readinessObserver.isPreparing {
                            ProgressView()
                                .tint(color)
                                .scaleEffect(0.65)
                        }
                        Text(actionTitle)
                            .font(Typography.monoCardTitle)
                    }
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .overlay(Rectangle().stroke(color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(readinessObserver.isPreparing)
                .accessibilityIdentifier(AccessibilityID.ClawStore.prepareGuestImageButton)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoyehtTheme.bgCard)
        .overlay(Rectangle().stroke(color.opacity(0.65), lineWidth: 1))
        .padding(.top, 8)
        .accessibilityIdentifier(AccessibilityID.ClawStore.guestImageGate)
    }

    private func startGuestImagePreparation(force: Bool) {
        Task {
            await readinessObserver.prepare(
                target: installTarget,
                resolution: resolution,
                force: force
            )
        }
    }

    /// Re-check Mac status WITHOUT a prepare request (the "Check Again" action).
    private func refreshGuestImageStatus() {
        Task {
            await readinessObserver.refreshStatus(target: installTarget, resolution: resolution)
        }
    }

    /// CTA -> handler. The CTA is decided by `GuestImageRecoveryPolicy`: prepare
    /// re-invokes guest-image preparation, checkAgain only refreshes status.
    private func guestImageRecoveryHandler(for cta: GuestImageRecoveryCTA) -> (() -> Void)? {
        switch cta {
        case .prepare:
            return { startGuestImagePreparation(force: true) }
        case .checkAgain:
            return { refreshGuestImageStatus() }
        case .none:
            return nil
        }
    }

    private func detailRoute(for claw: Claw) -> ClawRoute {
        // PR-3: iOS Claw Store always routes by `serverId`. The resolver
        // decides at the next hop whether to use `.server(ctx)` or the
        // selected-Mac household endpoint — UI never has to know.
        .detail(claw, serverId: installTarget.serverID)
    }
}
