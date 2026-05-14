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
        case needsNaming(engineURL: URL, claimToken: Data)
        case connectedToExistingMac
    }

    let invitation: SetupInvitationPayload
    let onMacFound: (Result) -> Void
    let onCancel: () -> Void

    @StateObject private var viewModel: AwaitingMacViewModel

    init(
        invitation: SetupInvitationPayload,
        onMacFound: @escaping (Result) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.invitation = invitation
        self.onMacFound = onMacFound
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: AwaitingMacViewModel(invitation: invitation))
    }

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                dismissBar

                Spacer()

                VStack(spacing: 32) {
                    if let house = viewModel.pendingExistingHouse {
                        existingHouseCard(house)
                    } else {
                        pulsatingRadar

                        VStack(spacing: 10) {
                            Text(LocalizedStringResource(
                                "awaitingMac.title",
                                defaultValue: "Looking for Soyeht on your Mac...",
                                comment: "Awaiting Mac discovery title. Ellipsis indicates ongoing search."
                            ))
                            .font(OnboardingFonts.heading)
                            .foregroundColor(BrandColors.textPrimary)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                            Text(LocalizedStringResource(
                                "awaitingMac.subtitle",
                                defaultValue: "Keep this screen open. On your Mac, finish setup until Soyeht says \"Waiting for your iPhone.\"",
                                comment: "Awaiting Mac subtitle instructing the user to finish setup on Mac while the iPhone waits."
                            ))
                            .font(OnboardingFonts.subheadline)
                            .foregroundColor(BrandColors.textMuted)
                            .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear { viewModel.start(onMacFound: onMacFound) }
        .onDisappear { viewModel.stop() }
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

    private func existingHouseCard(_ house: AwaitingMacViewModel.ExistingHouseCandidate) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "house.and.flag")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(BrandColors.accentGreen)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(LocalizedStringResource(
                    "awaitingMac.existingHouse.title",
                    defaultValue: "Connect to \(house.name)",
                    comment: "Title shown when iPhone discovers an already-named Mac home."
                ))
                .font(OnboardingFonts.heading)
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "awaitingMac.existingHouse.subtitle",
                    defaultValue: "\(house.hostLabel) is ready to add this iPhone.",
                    comment: "Subtitle shown when iPhone discovers a Mac waiting for first iPhone pairing."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
            }

            if !viewModel.fingerprintWords.isEmpty {
                VStack(spacing: 10) {
                    Text(LocalizedStringResource(
                        "awaitingMac.existingHouse.securityCode",
                        defaultValue: "Home security code",
                        comment: "Label above the stable home fingerprint words for Mac-first no-QR pairing."
                    ))
                    .font(OnboardingFonts.caption2Bold)
                    .foregroundColor(BrandColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(viewModel.fingerprintWords.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 8) {
                                Text(verbatim: "\(index + 1)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(BrandColors.textMuted)
                                Text(verbatim: word)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundColor(BrandColors.textPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .background(BrandColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(BrandColors.border, lineWidth: 1)
                )
            }

            if let error = viewModel.errorMessage {
                Text(error)
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

    @Published private(set) var pendingExistingHouse: ExistingHouseCandidate?
    @Published private(set) var fingerprintWords: [String] = []
    @Published private(set) var isPairing = false
    @Published private(set) var errorMessage: String?

    nonisolated private let browserQueue = DispatchQueue(label: "com.soyeht.awaiting-mac.browser")

    init(invitation: SetupInvitationPayload) {
        self.publisher = SetupInvitationPublisher(invitation: invitation)
        self.tokenBytes = invitation.token.bytes
    }

    func start(onMacFound: @escaping (AwaitingMacView.Result) -> Void) {
        onMacFoundHandler = onMacFound
        publisher.onMacClaimed = { [weak self] claim in
            Task { @MainActor [weak self] in
                guard let self else { return }
                awaitingMacLogger.info("direct_claim_received existing_house=\((claim.existingHouse != nil), privacy: .public) local_pairing=\((claim.macLocalPairing != nil), privacy: .public) already_found=\(self.alreadyFound, privacy: .public)")
                guard !self.alreadyFound else { return }
                if let pairing = claim.macLocalPairing, claim.existingHouse == nil {
                    installMacLocalPairing(pairing)
                    self.installedLocalPairingForDiscovery = true
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
                await self.resolveDiscoveredMac(engineURL: claim.macEngineURL, claimToken: self.tokenBytes)
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
        onMacFoundHandler = nil
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
            using: .tailscaleOnly()
        )
        let tokenBytes = self.tokenBytes
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if let engineURL = awaitingMacExtractEngineURL(from: result) {
                        Task { @MainActor [weak self] in
                            guard let self, !self.alreadyFound else { return }
                            await self.resolveDiscoveredMac(engineURL: engineURL, claimToken: tokenBytes)
                        }
                    return
                }
            }
        }
        browser.start(queue: browserQueue)
        macBrowser = browser
    }

    private func resolveDiscoveredMac(engineURL: URL, claimToken: Data) async {
        guard !alreadyFound else { return }
        let decision = await awaitingMacBootstrapDecision(
            at: engineURL,
            canOpenExistingMac: installedLocalPairingForDiscovery
        )
        guard !alreadyFound else { return }

        switch decision {
        case .existingHouse(let house):
            alreadyFound = true
            presentExistingHouse(house, engineURL: engineURL, deferredLocalPairing: nil)
        case .connectedToExistingMac:
            alreadyFound = true
            onMacFoundHandler?(.connectedToExistingMac)
        case .needsNaming:
            alreadyFound = true
            onMacFoundHandler?(.needsNaming(
                engineURL: engineURL,
                claimToken: claimToken
            ))
        case .retryLater:
            break
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
private func installMacLocalPairing(_ pairing: SetupInvitationMacLocalPairing) {
    let store = PairedMacsStore.shared
    store.storeSecret(pairing.secret, for: pairing.macID)
    store.upsertMac(
        macID: pairing.macID,
        name: pairing.macName,
        host: pairing.host,
        presencePort: pairing.presencePort,
        attachPort: pairing.attachPort
    )
    PairedMacRegistry.shared.reconcileClients()
}

// MARK: - URL extraction (nonisolated — reads only Sendable value types from NWBrowser.Result)

private func awaitingMacExtractEngineURL(from result: NWBrowser.Result) -> URL? {
    guard case .service = result.endpoint else { return nil }
    guard case .bonjour(let txt) = result.metadata else { return nil }

    if let urlStr = txt["url"], let url = URL(string: urlStr) {
        return url
    }

    let port = Int(txt["port"] ?? txt["hh_port"] ?? "") ?? 8091
    if let host = txt["host"] ?? txt["hh_host"] {
        return URL(string: "http://\(host):\(port)")
    }

    return nil
}

private enum AwaitingMacBootstrapDecision {
    case existingHouse(SetupInvitationExistingHouse)
    case connectedToExistingMac
    case needsNaming
    case retryLater
}

private func awaitingMacBootstrapDecision(
    at engineURL: URL,
    canOpenExistingMac: Bool
) async -> AwaitingMacBootstrapDecision {
    let client = BootstrapStatusClient(baseURL: engineURL)
    for attempt in 0..<2 {
        do {
            let status = try await client.fetch()
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
                return .needsNaming
            }
        } catch {
            guard attempt == 0 else { return .retryLater }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
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
