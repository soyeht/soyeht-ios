import SwiftUI
import Network
import SoyehtCore

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
    private let publisher: SetupInvitationPublisher
    private let tokenBytes: Data
    private var macBrowser: NWBrowser?
    private var onMacFoundHandler: ((AwaitingMacView.Result) -> Void)?
    private var alreadyFound = false
    private var installedLocalPairingForDiscovery = false

    nonisolated private let browserQueue = DispatchQueue(label: "com.soyeht.awaiting-mac.browser")

    init(invitation: SetupInvitationPayload) {
        self.publisher = SetupInvitationPublisher(invitation: invitation)
        self.tokenBytes = invitation.token.bytes
    }

    func start(onMacFound: @escaping (AwaitingMacView.Result) -> Void) {
        onMacFoundHandler = onMacFound
        publisher.onMacClaimed = { [weak self] claim in
            Task { @MainActor [weak self] in
                guard let self, !self.alreadyFound else { return }
                if let pairing = claim.macLocalPairing {
                    installMacLocalPairing(pairing)
                    self.installedLocalPairingForDiscovery = true
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
            case .namedAwaitingPair, .uninitialized, .readyForNaming, .recovering:
                return .needsNaming
            }
        } catch {
            guard attempt == 0 else { return .retryLater }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
    return .retryLater
}
