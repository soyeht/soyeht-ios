import SwiftUI
import Network
import os
import SoyehtCore

private let awaitingMacLogger = Logger(subsystem: "com.soyeht.mobile", category: "awaiting-mac")

/// Scene PB4 — "Looking for your Mac..." (T064, FR-024).
/// iPhone publishes a setup-invitation via SetupInvitationPublisher while browsing for the Mac engine.
/// When the Mac engine's `_soyeht-household._tcp` service is discovered, transitions to naming.
struct AwaitingMacView: View {
    enum Result {
        case connectedToExistingMac
    }

    let invitation: SetupInvitationPayload
    let onMacFound: (Result) -> Void
    let onCancel: () -> Void
    let onUseDownloadLink: () -> Void
    let onSwitchToLinux: () -> Void

    @StateObject private var viewModel: AwaitingMacViewModel

    init(
        invitation: SetupInvitationPayload,
        onMacFound: @escaping (Result) -> Void,
        onCancel: @escaping () -> Void,
        onUseDownloadLink: @escaping () -> Void,
        onSwitchToLinux: @escaping () -> Void
    ) {
        self.invitation = invitation
        self.onMacFound = onMacFound
        self.onCancel = onCancel
        self.onUseDownloadLink = onUseDownloadLink
        self.onSwitchToLinux = onSwitchToLinux
        _viewModel = StateObject(wrappedValue: AwaitingMacViewModel(invitation: invitation))
    }

    private let palette = NeoPalette.cloud

    var body: some View {
        ZStack {
            palette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                dismissBar

                Spacer()

                VStack(spacing: 28) {
                    if let house = viewModel.pendingExistingHouse {
                        existingHouseCard(house)
                    } else {
                        NeoRadar(palette: palette, isSearching: true)

                        VStack(spacing: 12) {
                            Text(LocalizedStringResource(
                                "onboarding.looking.title",
                                defaultValue: "Looking for your Mac…",
                                comment: "I3: title while the phone searches."
                            ))
                            .font(NeoFont.title)
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                            // The status says which of six situations this is.
                            // One spinner for all of them is what made the
                            // screen impossible to act on.
                            Text(statusLine)
                                .font(NeoFont.body)
                                .foregroundStyle(palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("soyeht.onboarding.looking.status")

                            Text(LocalizedStringResource(
                                "onboarding.looking.tailscale",
                                defaultValue: "Wi-Fi finds your Mac. Tailscale connects it — turn it on for both.",
                                comment: "I3: the one network requirement, said once."
                            ))
                            .font(NeoFont.caption)
                            .foregroundStyle(palette.muted)
                            .multilineTextAlignment(.center)
                        }

                        if viewModel.showRecoveryHint {
                            recoverySection
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        #if DEBUG
                        if let diag = viewModel.diagnosticMessage {
                            Text(diag)
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.muted)
                                .multilineTextAlignment(.center)
                                .padding(.top, 8)
                        }
                        #endif
                    }
                }
                .padding(.horizontal, 28)
                .animation(.easeInOut(duration: 0.25), value: viewModel.showRecoveryHint)
                .animation(.easeInOut(duration: 0.25), value: viewModel.diagnosticMessage)

                Spacer()
            }
        }
        .environment(\.neoPalette, palette)
        .preferredColorScheme(.light)
        .onAppear { viewModel.start(onMacFound: onMacFound) }
        .onDisappear { viewModel.stop() }
    }

    /// One line per phase, in the terms someone standing between two devices
    /// would use.
    private var statusLine: LocalizedStringResource {
        switch viewModel.phase {
        case .looking:
            return LocalizedStringResource(
                "onboarding.looking.status.looking",
                defaultValue: "Nothing yet. Open Soyeht on your Mac.",
                comment: "I3 status: nothing has answered."
            )
        case .macSeen:
            return LocalizedStringResource(
                "onboarding.looking.status.seen",
                defaultValue: "Found something — checking whether it is your Mac.",
                comment: "I3 status: a service resolved but has not answered yet."
            )
        case .waitingForMacSetup:
            return LocalizedStringResource(
                "onboarding.looking.status.waitingSetup",
                defaultValue: "Your Mac is still being set up. Finish there and this will carry on.",
                comment: "I3 status: the engine answered and has no home yet."
            )
        case .waitingForMacOffer:
            return LocalizedStringResource(
                "onboarding.looking.status.waitingOffer",
                defaultValue: "Your Mac has a home. Waiting for it to offer this iPhone a code.",
                comment: "I3 status: named, waiting for the pairing offer."
            )
        case .offered, .connecting:
            return LocalizedStringResource(
                "onboarding.looking.status.connecting",
                defaultValue: "Connecting…",
                comment: "I3 status: pairing is under way."
            )
        case .paired:
            return LocalizedStringResource(
                "onboarding.looking.status.paired",
                defaultValue: "Connected.",
                comment: "I3 status: done."
            )
        case .stalled:
            return LocalizedStringResource(
                "onboarding.looking.status.stalled",
                defaultValue: "Still nothing. One of these usually explains it.",
                comment: "I3 status: the search needs help."
            )
        }
    }

    private var dismissBar: some View {
        HStack {
            Button(action: onCancel) {
                Text(LocalizedStringResource(
                    "awaitingMac.cancel",
                    defaultValue: "Cancel",
                    comment: "Cancel button on awaiting Mac screen."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var pulsatingRadar: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                PulseRing(delay: Double(i) * 0.5)
            }

            Image(systemName: "wave.3.forward")
                .font(.system(size: 36))
                .foregroundColor(BrandColors.accentGreen)
        }
        .frame(width: 120, height: 120)
        .accessibilityHidden(true)
    }

    /// I8 — what to do about it. Each row is a cause the phone can actually
    /// distinguish, not a list of everything that could ever be wrong.
    private var recoverySection: some View {
        VStack(spacing: 14) {
            Text(LocalizedStringResource(
                "onboarding.notFound.title",
                defaultValue: "I can't find your Mac yet.",
                comment: "I8: heading once the search has gone quiet."
            ))
            .font(NeoFont.heading)
            .foregroundStyle(palette.text)
            .multilineTextAlignment(.center)

            ForEach(causes, id: \.self) { cause in
                NeoCard(palette: palette) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cause.title)
                            .font(NeoFont.cta)
                            .foregroundStyle(palette.text)
                        Text(cause.body)
                            .font(NeoFont.caption)
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }

            Button(action: { viewModel.restart() }) {
                Text(LocalizedStringResource(
                    "onboarding.notFound.keepLooking",
                    defaultValue: "Keep looking",
                    comment: "I8: restarts the search."
                ))
            }
            .buttonStyle(NeoPillButtonStyle(.primary, palette: palette, fillsWidth: false))
            .accessibilityIdentifier("soyeht.onboarding.notFound.keepLooking")

            Button(action: onUseDownloadLink) {
                Text(LocalizedStringResource(
                    "onboarding.notFound.getLink",
                    defaultValue: "Don't have Soyeht on the Mac yet? Get the link",
                    comment: "I8: sends the Mac download link."
                ))
            }
            .buttonStyle(NeoLinkButtonStyle(palette: palette))

            Button(action: onSwitchToLinux) {
                Text(LocalizedStringResource(
                    "onboarding.notFound.linux",
                    defaultValue: "I use Linux, not a Mac",
                    comment: "I8: switches to the Linux pairing guide."
                ))
            }
            .buttonStyle(NeoLinkButtonStyle(palette: palette))
        }
    }

    private struct Cause: Hashable {
        let title: LocalizedStringResource
        let body: LocalizedStringResource

        static func == (lhs: Cause, rhs: Cause) -> Bool {
            String(localized: lhs.title) == String(localized: rhs.title)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(String(localized: title))
        }
    }

    /// Derived from the phase, so the screen never lists a cause the phone has
    /// already ruled out.
    private var causes: [Cause] {
        var result: [Cause] = []

        if case .waitingForMacOffer = viewModel.phase {
            result.append(Cause(
                title: LocalizedStringResource(
                    "onboarding.notFound.cause.tailscale.title",
                    defaultValue: "Turn on Tailscale on both",
                    comment: "I8 cause: the LAN closes once the Mac has a home."
                ),
                body: LocalizedStringResource(
                    "onboarding.notFound.cause.tailscale.body",
                    defaultValue: "Once your Mac has a home it only accepts this over Tailscale. Wi-Fi alone is not enough.",
                    comment: "I8 cause body: why Wi-Fi stops being enough."
                )
            ))
        } else {
            result.append(Cause(
                title: LocalizedStringResource(
                    "onboarding.notFound.cause.openMac.title",
                    defaultValue: "Open Soyeht on the Mac",
                    comment: "I8 cause: nothing is advertising."
                ),
                body: LocalizedStringResource(
                    "onboarding.notFound.cause.openMac.body",
                    defaultValue: "It has to be running for this iPhone to see it.",
                    comment: "I8 cause body."
                )
            ))
            result.append(Cause(
                title: LocalizedStringResource(
                    "onboarding.notFound.cause.network.title",
                    defaultValue: "Same Wi-Fi, or Tailscale on both",
                    comment: "I8 cause: the two devices cannot see each other."
                ),
                body: LocalizedStringResource(
                    "onboarding.notFound.cause.network.body",
                    defaultValue: "Guest and hotel networks block this.",
                    comment: "I8 cause body."
                )
            ))
        }

        if case .stalled(.macUnreachable(.portMismatch(let observed, let expected))) = viewModel.phase {
            result.append(Cause(
                title: LocalizedStringResource(
                    "onboarding.notFound.cause.port.title",
                    defaultValue: "This iPhone and that Mac are different builds",
                    comment: "I8 cause: dev versus release, said by the numbers."
                ),
                body: LocalizedStringResource(
                    "onboarding.notFound.cause.port.body",
                    defaultValue: "It answered on port \(observed); this build talks to \(expected).",
                    comment: "I8 cause body with the two ports."
                )
            ))
        }

        return result
    }

    private func existingHouseCard(_ house: AwaitingMacViewModel.ExistingHouseCandidate) -> some View {
        VStack(spacing: 22) {
            NeoCard(palette: palette) {
                HStack(spacing: 14) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: house.hostLabel)
                            .font(NeoFont.heading)
                            .foregroundStyle(palette.text)
                        Text(verbatim: house.name)
                            .font(NeoFont.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .accessibilityIdentifier("soyeht.onboarding.isThisYourMac.card")

            VStack(spacing: 8) {
                Text(LocalizedStringResource(
                    "onboarding.isThisYourMac.title",
                    defaultValue: "Is this your Mac?",
                    comment: "I4: the question, asked once."
                ))
                .font(NeoFont.title)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "onboarding.isThisYourMac.body",
                    defaultValue: "Your Mac is showing the same six words. If they match, connect.",
                    comment: "I4: what the person compares."
                ))
                .font(NeoFont.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            }

            if !viewModel.fingerprintWords.isEmpty {
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { column in
                                let index = row * 3 + column
                                if index < viewModel.fingerprintWords.count {
                                    NeoWordWell(
                                        index: index + 1,
                                        word: viewModel.fingerprintWords[index],
                                        palette: palette
                                    )
                                    .accessibilityIdentifier("soyeht.onboarding.isThisYourMac.word.\(index + 1)")
                                }
                            }
                        }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(OnboardingFonts.caption)
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
            } else if viewModel.isPairing, house.isDevicePairing {
                // Delegated pairing: this home already has an iPhone, and
                // only that iPhone can approve a new one. Measured
                // 2026-09-01: with no such iPhone left, this screen showed a
                // bare spinner for the whole approval window and the person
                // had no idea what they were waiting for.
                Text(LocalizedStringResource(
                    "awaitingMac.existingHouse.waitingForApproval",
                    defaultValue: "Waiting for approval from an iPhone that already belongs to this home.",
                    comment: "Shown while a new iPhone waits for an existing iPhone in the home to approve it."
                ))
                .font(OnboardingFonts.caption)
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
            }

            Button(action: { viewModel.connectToExistingHouse() }) {
                if viewModel.isPairing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(BrandColors.buttonTextOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    Text(LocalizedStringResource(
                        "awaitingMac.existingHouse.connect",
                        defaultValue: "Connect this iPhone",
                        comment: "CTA that pairs this iPhone to the discovered existing Mac home."
                    ))
                    .font(OnboardingFonts.bodyBold)
                    .foregroundColor(BrandColors.buttonTextOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }
            .disabled(viewModel.isPairing)
            .background(BrandColors.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - PulseRing

private struct PulseRing: View {
    let delay: Double
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .stroke(BrandColors.accentGreen.opacity(opacity), lineWidth: 1.5)
            .scaleEffect(scale)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeOut(duration: 1.8)
                    .delay(delay)
                    .repeatForever(autoreverses: false)
                ) {
                    scale = 1.4
                    opacity = 0
                }
            }
    }
}

// MARK: - ViewModel

@MainActor
final class AwaitingMacViewModel: ObservableObject {
    struct ExistingHouseCandidate: Equatable, Identifiable {
        var id: String { pairDeviceURI.absoluteString }
        let name: String
        let hostLabel: String
        let pairDeviceURI: URL
        let engineURL: URL
        let isDevicePairing: Bool
        let deferredLocalPairing: SetupInvitationMacLocalPairing?
    }

    private let publisher: SetupInvitationPublisher
    private let tokenBytes: Data
    private var macBrowser: NWBrowser?
    private var onMacFoundHandler: ((AwaitingMacView.Result) -> Void)?
    private var alreadyFound = false
    private var installedLocalPairingForDiscovery = false
    private var recoveryHintTask: Task<Void, Never>?
    private var macBrowserResolutionTask: Task<Void, Never>?

    /// Seconds to wait with no successful Mac discovery before revealing the
    /// "Not finding your Mac?" recovery section underneath the radar.
    /// From the OnboardingConfig SSOT (default 20s, pinned by `OnboardingConfigTests`);
    /// behavior-equivalent to the prior literal `20`. Kept as `UInt64` seconds so the
    /// existing `* 1_000_000_000` nanosecond sleep mechanism is unchanged.
    private static let recoveryHintDelaySeconds: UInt64 = UInt64(OnboardingConfig.default.macDiscoveryRecoveryHintDelay)

    @Published private(set) var pendingExistingHouse: ExistingHouseCandidate?
    @Published private(set) var fingerprintWords: [String] = []
    @Published private(set) var isPairing = false
    @Published private(set) var errorMessage: String?
    @Published var showRecoveryHint: Bool = false
    /// What the phone is actually doing, so the radar can say it. The old
    /// screen had one spinner for six situations and no way to tell them
    /// apart.
    @Published private(set) var phase: MacDiscoveryPhase = .looking(sawService: false)
    /// Temporary in-flow diagnostic surface so users (and us, during e2e
    /// validation) can see which step the claim handshake is on without
    /// needing to attach to iPhone os_log. Updated from onMacClaimed and the
    /// resolveDiscoveredMac retry loop.
    @Published var diagnosticMessage: String?

    nonisolated private let browserQueue = DispatchQueue(label: "com.soyeht.awaiting-mac.browser")

    init(invitation: SetupInvitationPayload) {
        self.publisher = SetupInvitationPublisher(invitation: invitation)
        self.tokenBytes = invitation.token.bytes
    }

    func start(onMacFound: @escaping (AwaitingMacView.Result) -> Void) {
        // Wrap the supplied handler so any successful discovery decision also
        // cancels the recovery-hint timer (and hides the hint if it had fired
        // moments before the success arrived).
        onMacFoundHandler = { [weak self] result in
            self?.cancelRecoveryHint()
            onMacFound(result)
        }
        scheduleRecoveryHint()
        publisher.onMacClaimed = { [weak self] claim in
            Task { @MainActor [weak self] in
                guard let self else { return }
                awaitingMacLogger.info("direct_claim_received existing_house=\((claim.existingHouse != nil), privacy: .public) local_pairing=\((claim.macLocalPairing != nil), privacy: .public) already_found=\(self.alreadyFound, privacy: .public)")
                // Bug 1 instrumentation (2026-05-21): dump the engine URL
                // structure as the Foundation URL parser sees it. If the
                // raw JSON string from the engine is well-formed but the
                // URL gets mangled here (scheme/host/port drift), the
                // log delta will make it obvious.
                awaitingMacLogger.info("claim.received url=\(claim.macEngineURL.absoluteString, privacy: .public) scheme=\(claim.macEngineURL.scheme ?? "<nil>", privacy: .public) host=\(claim.macEngineURL.host ?? "<nil>", privacy: .public) port=\(claim.macEngineURL.port.map(String.init) ?? "<nil>", privacy: .public)")
                self.diagnosticMessage = "Mac claim arrived — connecting to \(claim.macEngineURL.absoluteString)"
                guard !self.alreadyFound else { return }
                guard Self.engineURLMatchesCurrentInstallProfile(claim.macEngineURL) else {
                    awaitingMacLogger.info(
                        "direct_claim_ignored_profile_mismatch expected_port=\(EndpointPolicy.defaultBootstrapPort(), privacy: .public) claim_port=\(claim.macEngineURL.port.map(String.init) ?? "<nil>", privacy: .public)"
                    )
                    return
                }
                if let existingHouse = claim.existingHouse {
                    awaitingMacLogger.info("direct_claim_present_existing_house")
                    self.alreadyFound = true
                    self.presentExistingHouse(
                        existingHouse,
                        engineURL: claim.macEngineURL,
                        deferredLocalPairing: claim.macLocalPairing
                    )
                    return
                }
                await self.resolveDiscoveredMac(
                    engineURL: claim.macEngineURL,
                    claimToken: self.tokenBytes,
                    localPairing: claim.macLocalPairing
                )
            }
        }
        publisher.start()
        startMacBrowser()
    }

    func stop() {
        publisher.stop()
        publisher.onMacClaimed = nil
        macBrowser?.cancel()
        macBrowser = nil
        macBrowserResolutionTask?.cancel()
        macBrowserResolutionTask = nil
        onMacFoundHandler = nil
        alreadyFound = false
        cancelRecoveryHint()
    }

    /// "Keep looking" — a real restart, not a cosmetic reset. The old screen
    /// had no way back once it gave up.
    func restart() {
        let handler = onMacFoundHandler
        stop()
        phase = .looking(sawService: false)
        showRecoveryHint = false
        if let handler { start(onMacFound: handler) }
    }

    private func scheduleRecoveryHint() {
        recoveryHintTask?.cancel()
        recoveryHintTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.recoveryHintDelaySeconds * 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // Don't pop the hint if a Mac was already discovered (either an
            // existing-house card is showing, or onMacFound has already fired).
            guard self.pendingExistingHouse == nil, !self.alreadyFound else { return }
            self.showRecoveryHint = true
        }
    }

    private func cancelRecoveryHint() {
        recoveryHintTask?.cancel()
        recoveryHintTask = nil
        if showRecoveryHint { showRecoveryHint = false }
    }

    func connectToExistingHouse() {
        guard let house = pendingExistingHouse, !isPairing else { return }
        isPairing = true
        errorMessage = nil

        Task {
            do {
                if house.isDevicePairing {
                    let link = try HouseholdDevicePairingLink(url: house.pairDeviceURI)
                    _ = try await HouseholdDevicePairingService(
                        keyProvider: SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
                    ).pair(link: link)
                } else {
                    _ = try await HouseholdPairingService(
                        browser: DirectExistingHousePairingBrowser(
                            endpoint: house.engineURL,
                            householdName: house.name
                        ),
                        keyProvider: SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
                    ).pair(
                        url: house.pairDeviceURI,
                        displayName: HouseholdOwnerDisplayName.defaultName()
                    )
                }
                do {
                    _ = try await APNSRegistrationCoordinator.shared.handleSessionActivated()
                } catch {
                    // Pairing is complete; APNs registration can recover from
                    // foreground/app lifecycle hooks without blocking entry.
                }
                try Task.checkCancellation()
                await MainActor.run {
                    if let pairing = house.deferredLocalPairing {
                        installMacLocalPairing(pairing)
                    }
                    self.isPairing = false
                    self.onMacFoundHandler?(.connectedToExistingMac)
                }
            } catch is CancellationError {
            } catch HouseholdDevicePairingError.approvalTimedOut {
                awaitingMacLogger.error("existing_house_pair_failed error=approvalTimedOut")
                await MainActor.run {
                    self.isPairing = false
                    // Not a network failure: the request reached the Mac and
                    // sat unapproved until it expired. The only iPhone that
                    // could approve it may be gone; say so, and say what fixes it.
                    self.errorMessage = String(localized: LocalizedStringResource(
                        "awaitingMac.existingHouse.connect.approvalTimedOut",
                        defaultValue: "No iPhone in this home approved the request. If that iPhone is gone, open Soyeht on the Mac, go to Preferences › Devices, and choose Start over — then pair this iPhone as the first one.",
                        comment: "Shown when delegated device pairing expires without approval from an existing iPhone."
                    ))
                }
            } catch {
                awaitingMacLogger.error("existing_house_pair_failed error=\(String(describing: error), privacy: .public)")
                await MainActor.run {
                    self.isPairing = false
                    self.errorMessage = String(localized: LocalizedStringResource(
                        "awaitingMac.existingHouse.connect.failed",
                        defaultValue: "I couldn't connect this time. Keep Soyeht open on your Mac and try again.",
                        comment: "Recoverable error shown when no-QR existing-house pairing does not complete."
                    ))
                }
            }
        }
    }

    // MARK: - Private

    private func startMacBrowser() {
        macBrowser?.cancel()
        macBrowser = nil
        let browser = NWBrowser(
            for: .bonjour(type: "_soyeht-household._tcp", domain: nil),
            using: .localNetworkAndTailscale()
        )
        let tokenBytes = self.tokenBytes
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let engineURLs = Self.macEngineURLs(in: results, phase: "browseChanged")
            if Self.containsCurrentInstallProfileEndpoint(engineURLs) {
                Task { @MainActor [weak self] in
                    guard let self, !self.alreadyFound else { return }
                    await self.resolveDiscoveredMac(engineURLs: engineURLs, claimToken: tokenBytes)
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.scheduleMacBrowserResolutionPolls(for: results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let message: String?
            switch state {
            case .setup:
                message = "Preparing Mac discovery..."
            case .ready:
                message = "Scanning local network and Tailscale..."
            case .waiting(let error):
                message = "Waiting for network permission/path: \(error.localizedDescription)"
            case .failed(let error):
                message = "Mac discovery failed: \(error.localizedDescription)"
            case .cancelled:
                message = nil
            @unknown default:
                message = nil
            }
            guard let message else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.alreadyFound, self.pendingExistingHouse == nil else { return }
                self.diagnosticMessage = message
            }
        }
        browser.start(queue: browserQueue)
        macBrowser = browser
    }

    private func scheduleMacBrowserResolutionPolls(for results: Set<NWBrowser.Result>) {
        macBrowserResolutionTask?.cancel()
        macBrowserResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled, !self.alreadyFound else { return }

            var engineURLs = Self.macEngineURLs(in: results, phase: "metadataPoll+0ms")
            if Self.containsCurrentInstallProfileEndpoint(engineURLs) {
                await self.resolveDiscoveredMac(engineURLs: engineURLs, claimToken: self.tokenBytes)
                return
            }

            engineURLs = await Self.macEngineURLsViaDNSSD(in: results)
            if Self.containsCurrentInstallProfileEndpoint(engineURLs) {
                guard !Task.isCancelled, !self.alreadyFound else { return }
                await self.resolveDiscoveredMac(engineURLs: engineURLs, claimToken: self.tokenBytes)
                return
            }

            for delayMs in [300, 700, 1500, 3000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                guard !Task.isCancelled, !self.alreadyFound else { return }
                engineURLs = Self.macEngineURLs(in: results, phase: "metadataPoll+\(delayMs)ms")
                if Self.containsCurrentInstallProfileEndpoint(engineURLs) {
                    await self.resolveDiscoveredMac(engineURLs: engineURLs, claimToken: self.tokenBytes)
                    return
                }

                engineURLs = await Self.macEngineURLsViaDNSSD(in: results)
                if Self.containsCurrentInstallProfileEndpoint(engineURLs) {
                    guard !Task.isCancelled, !self.alreadyFound else { return }
                    await self.resolveDiscoveredMac(engineURLs: engineURLs, claimToken: self.tokenBytes)
                    return
                }
            }
        }
    }

    nonisolated private static func macEngineURLs(
        in results: Set<NWBrowser.Result>,
        phase: String
    ) -> [URL] {
        var urls: [URL] = []
        for result in results {
            if let engineURL = awaitingMacExtractEngineURL(from: result) {
                awaitingMacLogger.info("mac_browser.endpoint phase=\(phase, privacy: .public) endpoint=\(engineURL.absoluteString, privacy: .public)")
                urls.append(engineURL)
            }
        }
        urls = deduplicatedMacEngineURLs(urls)
        if !urls.isEmpty { return urls }
        awaitingMacLogger.info("mac_browser.no_endpoint phase=\(phase, privacy: .public) result_count=\(results.count, privacy: .public)")
        return []
    }

    nonisolated private static func macEngineURLsViaDNSSD(
        in results: Set<NWBrowser.Result>
    ) async -> [URL] {
        var urls: [URL] = []
        for result in results {
            if let engineURL = await HouseholdBonjourBrowser.resolveEngineEndpointViaDNSSD(
                from: result,
                defaultPort: EndpointPolicy.defaultBootstrapPort()
            ) {
                awaitingMacLogger.info("mac_browser.endpoint phase=DNSServiceResolve endpoint=\(engineURL.absoluteString, privacy: .public)")
                urls.append(engineURL)
            }
        }
        urls = deduplicatedMacEngineURLs(urls)
        if !urls.isEmpty { return urls }
        awaitingMacLogger.info("mac_browser.no_endpoint phase=DNSServiceResolve result_count=\(results.count, privacy: .public)")
        return []
    }

    nonisolated private static func deduplicatedMacEngineURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = "\(url.scheme ?? "http")://\(url.host ?? ""):\(url.port ?? -1)"
            guard seen.insert(key).inserted else { continue }
            result.append(url)
        }
        return result
    }

    nonisolated private static func containsCurrentInstallProfileEndpoint(_ urls: [URL]) -> Bool {
        urls.contains { url in
            url.port == EndpointPolicy.defaultBootstrapPort()
        }
    }

    /// After the Mac POSTs `/setup-invitation/claimed`, the iPhone must reach
    /// the Mac's engine to decide where to route next (house naming, existing
    /// house card, or already-paired). The previous behaviour treated a single
    /// `retryLater` (status fetch failure or "ready but no pairing") as
    /// terminal, leaving the user stranded on AwaitingMacView with no
    /// indication that anything went wrong.
    ///
    /// This loop keeps retrying for up to ~60s. Transient races (engine still
    /// finishing claim, Tailnet route not yet settled, Wi-Fi roam) recover.
    /// Persistent failures surface a real error so the user can pick the
    /// download-link / Linux fallback instead of staring at a spinner.
    private func resolveDiscoveredMac(
        engineURL: URL,
        claimToken: Data,
        localPairing: SetupInvitationMacLocalPairing? = nil
    ) async {
        await resolveDiscoveredMac(
            engineURLs: [engineURL],
            claimToken: claimToken,
            localPairing: localPairing
        )
    }

    private func resolveDiscoveredMac(
        engineURLs: [URL],
        claimToken: Data,
        localPairing: SetupInvitationMacLocalPairing? = nil
    ) async {
        let engineURLs = Self.deduplicatedMacEngineURLs(engineURLs).filter { engineURL in
            let matches = Self.engineURLMatchesCurrentInstallProfile(engineURL)
            if !matches {
                awaitingMacLogger.info(
                    "mac_browser_ignored_profile_mismatch expected_port=\(EndpointPolicy.defaultBootstrapPort(), privacy: .public) endpoint_port=\(engineURL.port.map(String.init) ?? "<nil>", privacy: .public)"
                )
            }
            return matches
        }
        awaitingMacLogger.info("resolveDiscoveredMac.entry engines=\(engineURLs.map(\.absoluteString).joined(separator: ","), privacy: .public) already_found=\(self.alreadyFound, privacy: .public) can_open_existing=\(self.installedLocalPairingForDiscovery, privacy: .public)")
        diagnosticMessage = "Connecting to Mac..."
        guard !alreadyFound else { return }
        guard !engineURLs.isEmpty else { return }

        let deadline = Date().addingTimeInterval(OnboardingConfig.default.macDiscoveryDeadline)
        var attempts = 0
        while !alreadyFound, Date() < deadline {
            attempts += 1
            var lastRawErrText: String?
            var lastHostPort = "?"
            for engineURL in engineURLs {
                diagnosticMessage = "Reaching Mac (attempt \(attempts))..."
                let decision = await awaitingMacBootstrapDecision(
                    at: engineURL,
                    canOpenExistingMac: installedLocalPairingForDiscovery || localPairing != nil
                )
                awaitingMacLogger.info("resolveDiscoveredMac.decision attempt=\(attempts, privacy: .public) engine=\(engineURL.absoluteString, privacy: .public) result=\(String(describing: decision), privacy: .public)")
                guard !alreadyFound else { return }

                switch decision {
                case .existingHouse(let house):
                    alreadyFound = true
                    diagnosticMessage = "Mac already has a household — joining"
                    presentExistingHouse(house, engineURL: engineURL, deferredLocalPairing: localPairing)
                    return
                case .connectedToExistingMac:
                    if let localPairing {
                        installMacLocalPairing(localPairing)
                        installedLocalPairingForDiscovery = true
                    }
                    alreadyFound = true
                    diagnosticMessage = "Connected to existing Mac"
                    onMacFoundHandler?(.connectedToExistingMac)
                    return
                case .macIsBeingSetUp(let name):
                    // No latch and no deadline: the Mac is mid-setup and the
                    // phone's job is to keep watching until it has a home.
                    phase = .waitingForMacSetup(name: name)
                    diagnosticMessage = "Mac is still being set up"
                    cancelRecoveryHint()
                case .retryLater:
                    let rawErrText = await probeRawError(for: engineURL)
                    let hostPort = "\(engineURL.host ?? "?"):\(engineURL.port.map(String.init) ?? "?")"
                    lastRawErrText = rawErrText
                    lastHostPort = hostPort
                    awaitingMacLogger.info("resolveDiscoveredMac.retry_later attempt=\(attempts, privacy: .public) host_port=\(hostPort, privacy: .public) raw_err=\(rawErrText, privacy: .public)")
                }
            }
            diagnosticMessage = "Mac unreachable @ \(lastHostPort) (retry \(attempts)) — \(lastRawErrText ?? "no compatible endpoint")"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        diagnosticMessage = "Couldn't reach Mac engine after \(attempts) attempts"
        awaitingMacLogger.error("resolveDiscoveredMac.gave_up_after_attempts attempts=\(attempts, privacy: .public)")
    }

    private static func engineURLMatchesCurrentInstallProfile(_ engineURL: URL) -> Bool {
        guard let port = engineURL.port else { return false }
        return port == EndpointPolicy.defaultBootstrapPort()
    }

    /// Bypasses `BootstrapStatusClient`'s `.networkDrop` wrapping to expose the
    /// raw NSURLErrorDomain code. Used only for the on-screen diagnostic.
    private func probeRawError(for engineURL: URL) async -> String {
        let probe = engineURL.appendingPathComponent("bootstrap/status")
        // Bug 1 instrumentation (2026-05-21): log the URL the way URLSession
        // sees it right before it issues the request. If the on-wire URL is
        // not exactly the expected `http://<tailnet-ipv4>:8091/bootstrap/status`,
        // -1022 has a non-ATS root cause and we patch construction, not
        // Info.plist.
        awaitingMacLogger.info("probe.url string=\(probe.absoluteString, privacy: .public) scheme=\(probe.scheme ?? "<nil>", privacy: .public) host=\(probe.host ?? "<nil>", privacy: .public) port=\(probe.port.map(String.init) ?? "<nil>", privacy: .public)")
        var req = URLRequest(url: probe)
        req.timeoutInterval = OnboardingConfig.default.macProbeTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = OnboardingConfig.default.macProbeTimeout
        config.timeoutIntervalForResource = OnboardingConfig.default.macProbeTimeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                return "HTTP \(http.statusCode) (unexpected — should have decoded)"
            }
            return "non-HTTP response"
        } catch let urlError as URLError {
            return "URLError.\(urlError.code.rawValue) \(urlError.localizedDescription)"
        } catch {
            return "\(type(of: error)): \(error.localizedDescription)"
        }
    }

    private func presentExistingHouse(
        _ house: SetupInvitationExistingHouse,
        engineURL: URL,
        deferredLocalPairing: SetupInvitationMacLocalPairing?
    ) {
        guard !alreadyFound || pendingExistingHouse == nil else { return }
        guard let pairURL = URL(string: house.pairDeviceURI) else {
            errorMessage = String(localized: LocalizedStringResource(
                "awaitingMac.existingHouse.invalidLink",
                defaultValue: "I found your Mac, but couldn't verify its pairing link. Try the QR fallback on the Mac.",
                comment: "Error shown when the Mac sends an invalid first-owner pairing URI."
            ))
            return
        }
        let isDevicePairing = Self.isDevicePairingURL(pairURL)
        let effectivePairURL: URL
        if isDevicePairing {
            do {
                let link = try HouseholdDevicePairingLink(url: pairURL)
                effectivePairURL = try HouseholdDevicePairingLink(
                    endpoint: engineURL,
                    householdId: link.householdId,
                    householdPublicKey: link.householdPublicKey,
                    householdName: link.householdName,
                    pairingNonce: link.pairingNonce
                ).url()
                fingerprintWords = try pairDeviceFingerprintWords(for: effectivePairURL, now: Date())
            } catch {
                errorMessage = String(localized: LocalizedStringResource(
                    "awaitingMac.existingHouse.invalidLink",
                    defaultValue: "I found your Mac, but couldn't verify its pairing link. Try the QR fallback on the Mac.",
                    comment: "Error shown when the Mac sends an invalid first-owner pairing URI."
                ))
                return
            }
        } else {
            effectivePairURL = pairURL
            do {
                fingerprintWords = try pairDeviceFingerprintWords(for: pairURL, now: Date())
            } catch {
                errorMessage = String(localized: LocalizedStringResource(
                    "awaitingMac.existingHouse.invalidSecurityCode",
                    defaultValue: "I found your Mac, but couldn't verify its security code. Try the QR fallback on the Mac.",
                    comment: "Error shown when the iPhone cannot derive the security code from the pairing URI."
                ))
                return
            }
        }
        pendingExistingHouse = ExistingHouseCandidate(
            name: house.name,
            hostLabel: house.hostLabel,
            pairDeviceURI: effectivePairURL,
            engineURL: engineURL,
            isDevicePairing: isDevicePairing,
            deferredLocalPairing: deferredLocalPairing
        )
        // We're now showing the existing-house connect card; the recovery
        // hint must not flash up alongside it.
        cancelRecoveryHint()
    }

    private static func isDevicePairingURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "soyeht"
            && components.host == "household"
            && components.path == "/device-pairing"
    }
}

@MainActor
func installMacLocalPairing(_ pairing: SetupInvitationMacLocalPairing) {
    let store = PairedMacsStore.shared
    store.storeSecret(pairing.secret, for: pairing.macID)
    ServerRegistry.shared.upsertMacPairing(
        macID: pairing.macID,
        name: pairing.macName,
        host: pairing.host,
        presencePort: pairing.presencePort,
        attachPort: pairing.attachPort
    )
    _ = ServerRegistry.shared.setDefaultMacAliasIfNeeded(
        macID: pairing.macID,
        suggestedAlias: pairing.macName
    )
    PairedMacRegistry.shared.reconcileClients()
}

// MARK: - URL extraction (nonisolated — reads only Sendable value types from NWBrowser.Result)

private func awaitingMacExtractEngineURL(from result: NWBrowser.Result) -> URL? {
    HouseholdBonjourBrowser.engineEndpointURL(from: result)
}

private enum AwaitingMacBootstrapDecision {
    case existingHouse(SetupInvitationExistingHouse)
    case connectedToExistingMac
    /// The engine answered and has no home yet. Keep looking; do not latch.
    case macIsBeingSetUp(name: String?)
    case retryLater
}

private func awaitingMacBootstrapDecision(
    at engineURL: URL,
    canOpenExistingMac: Bool
) async -> AwaitingMacBootstrapDecision {
    let client = BootstrapStatusClient(baseURL: engineURL)
    awaitingMacLogger.info("bootstrap_decision.start engine=\(engineURL.absoluteString, privacy: .public)")
    for attempt in 0..<2 {
        do {
            let status = try await client.fetch()
            awaitingMacLogger.info("bootstrap_decision.fetched attempt=\(attempt, privacy: .public) state=\(String(describing: status.state), privacy: .public)")
            switch status.state {
            case .ready:
                return canOpenExistingMac ? .connectedToExistingMac : .retryLater
            case .namedAwaitingPair:
                if let response = try? await BootstrapPairDeviceURIClient(baseURL: engineURL).fetch() {
                    return .existingHouse(SetupInvitationExistingHouse(
                        name: response.houseName,
                        hostLabel: response.hostLabel,
                        pairDeviceURI: response.pairDeviceURI
                    ))
                }
                return .retryLater
            case .uninitialized, .readyForNaming, .recovering:
                // Someone is at the Mac finishing setup. This used to end the
                // search — the phone latched, stopped looking, and never
                // noticed when the Mac named itself moments later.
                return .macIsBeingSetUp(name: status.hostLabel)
            }
        } catch {
            awaitingMacLogger.info("bootstrap_decision.fetch_failed attempt=\(attempt, privacy: .public) err=\(String(describing: error), privacy: .public)")
            guard attempt == 0 else { return .retryLater }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
    awaitingMacLogger.info("bootstrap_decision.exhausted_retries engine=\(engineURL.absoluteString, privacy: .public)")
    return .retryLater
}

private struct DirectExistingHousePairingBrowser: HouseholdBonjourBrowsing {
    let endpoint: URL
    let householdName: String

    func firstMatchingCandidate(
        for qr: PairDeviceQR,
        timeout: TimeInterval
    ) async throws -> HouseholdDiscoveryCandidate {
        HouseholdDiscoveryCandidate(
            endpoint: endpoint,
            householdId: qr.householdId,
            householdName: householdName,
            machineId: nil,
            pairingState: "device",
            shortNonce: qr.shortNonce
        )
    }
}
