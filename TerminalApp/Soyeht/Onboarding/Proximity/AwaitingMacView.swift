import SwiftUI
import Network
import SoyehtCore

/// Cena PB4 — "Procurando seu Mac..." (T064, FR-024).
/// iPhone publishes a setup-invitation via SetupInvitationPublisher while browsing for the Mac engine.
/// When the Mac engine's `_soyeht-household._tcp` service is discovered, transitions to naming.
struct AwaitingMacView: View {
    let invitation: SetupInvitationPayload
    let onMacFound: (URL, Data) -> Void
    let onCancel: () -> Void

    @StateObject private var viewModel: AwaitingMacViewModel

    init(
        invitation: SetupInvitationPayload,
        onMacFound: @escaping (URL, Data) -> Void,
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
                            defaultValue: "Procurando seu Mac…",
                            comment: "Awaiting Mac discovery title. Ellipsis indicates ongoing search."
                        ))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "awaitingMac.subtitle",
                            defaultValue: "Certifique-se que o Mac está na mesma rede.",
                            comment: "Awaiting Mac subtitle instructing user to be on the same network."
                        ))
                        .font(.system(size: 15))
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
                    defaultValue: "Cancelar",
                    comment: "Cancel button on awaiting Mac screen."
                ))
                .font(.system(size: 15))
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
    private var onMacFoundHandler: ((URL, Data) -> Void)?

    nonisolated private let browserQueue = DispatchQueue(label: "com.soyeht.awaiting-mac.browser")

    init(invitation: SetupInvitationPayload) {
        self.publisher = SetupInvitationPublisher(invitation: invitation)
        self.tokenBytes = invitation.token.bytes
    }

    func start(onMacFound: @escaping (URL, Data) -> Void) {
        onMacFoundHandler = onMacFound
        publisher.start()
        startMacBrowser()
    }

    func stop() {
        publisher.stop()
        macBrowser?.cancel()
        macBrowser = nil
        onMacFoundHandler = nil
    }

    // MARK: - Private

    private func startMacBrowser() {
        let browser = NWBrowser(
            for: .bonjour(type: "_soyeht-household._tcp", domain: nil),
            using: .tcp
        )
        let tokenBytes = self.tokenBytes
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if let engineURL = awaitingMacExtractEngineURL(from: result) {
                    Task { @MainActor [weak self] in
                        self?.onMacFoundHandler?(engineURL, tokenBytes)
                    }
                    return
                }
            }
        }
        browser.start(queue: browserQueue)
        macBrowser = browser
    }
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
