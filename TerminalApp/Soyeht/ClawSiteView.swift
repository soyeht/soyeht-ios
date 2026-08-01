import SwiftUI
import WebKit
import SoyehtCore

/// Everything the web view needs to render one shared claw's app: the URL to
/// load and the handler that will serve it.
///
/// These travel together because the handler must be registered on the
/// `WKWebViewConfiguration` *before* the web view exists — handing back a bare
/// URL would leave the caller with an address nothing answers.
struct ClawSiteSource {
    let url: URL
    let handler: ClawSiteURLSchemeHandler
}

/// Resolves how a shared claw's **ClawSite** is reachable from this device.
///
/// The engine's `ClawSite` relay-stream resource forwards an authorized tunnel to
/// the claw's own HTTP backend (`THEYOS_RELAY_STREAM_CLAWSITE_BACKEND`), so the
/// guest speaks plain HTTP/1.1 end to end.
///
/// Kept behind a protocol for the same reason `OwnerGroupsReading` is: the screen
/// never changes when the live resolver replaces the unavailable one.
protocol ClawSiteEndpointProviding: Sendable {
    /// A source for `clawName`, or `nil` when this device cannot currently
    /// reach it. Returning `nil` is a first-class answer — the UI renders an
    /// honest unavailable state rather than inventing an endpoint, mirroring
    /// the engine router's fail-closed behaviour.
    func source(forClaw clawName: String) async -> ClawSiteSource?
}

/// Resolves nothing, on purpose: no invented endpoint, no silent fallback.
/// Used where a claw has no claimed ClawSite offer to serve from.
struct UnavailableClawSiteEndpointProvider: ClawSiteEndpointProviding {
    func source(forClaw _: String) async -> ClawSiteSource? { nil }
}

/// Serves a claw whose ClawSite offer this device has already claimed.
struct ClaimedClawSiteEndpointProvider: ClawSiteEndpointProviding {
    let bridge: ClawSiteHTTPBridge

    func source(forClaw _: String) async -> ClawSiteSource? {
        ClawSiteSource(
            url: ClawSiteURLSchemeHandler.rootURL,
            handler: ClawSiteURLSchemeHandler(bridge: bridge)
        )
    }
}

@MainActor
final class ClawSiteViewModel: ObservableObject {
    enum Phase: Equatable {
        case resolving
        case ready(ClawSiteSource)
        case unavailable
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.resolving, .resolving), (.unavailable, .unavailable):
                return true
            case (.ready(let l), .ready(let r)):
                return l.url == r.url && l.handler === r.handler
            case (.failed(let l), .failed(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    @Published private(set) var phase: Phase = .resolving

    let clawName: String
    private let provider: ClawSiteEndpointProviding

    init(clawName: String, provider: ClawSiteEndpointProviding) {
        self.clawName = clawName
        self.provider = provider
    }

    func resolve() async {
        phase = .resolving
        if let source = await provider.source(forClaw: clawName) {
            phase = .ready(source)
        } else {
            phase = .unavailable
        }
    }

    func reportLoadFailure(_ message: String) {
        phase = .failed(message)
    }
}

/// `WKWebView` host. The claw's app is ordinary HTML served by the claw itself,
/// so it renders exactly as its author wrote it — any language, any framework.
private struct ClawSiteWebView: UIViewRepresentable {
    let source: ClawSiteSource
    let onFailure: (String) -> Void

    private var url: URL { source.url }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The claw's site is private to the invited guest; keep nothing behind.
        configuration.websiteDataStore = .nonPersistent()
        // Must be registered before the web view is constructed — WebKit reads
        // the handler table at init and ignores later additions.
        configuration.setURLSchemeHandler(source.handler, forURLScheme: ClawSiteURLSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onFailure: (String) -> Void

        init(onFailure: @escaping (String) -> Void) {
            self.onFailure = onFailure
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            onFailure(error.localizedDescription)
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError error: Error
        ) {
            onFailure(error.localizedDescription)
        }
    }
}

/// Full-screen view of one shared claw's app.
struct ClawSiteView: View {
    @StateObject private var model: ClawSiteViewModel

    init(model: ClawSiteViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            switch model.phase {
            case .resolving:
                status(icon: nil) {
                    ProgressView()
                    Text("Connecting to \(model.clawName)…")
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
            case .ready(let source):
                ClawSiteWebView(source: source) { message in
                    model.reportLoadFailure(message)
                }
                .ignoresSafeArea(edges: .bottom)
            case .unavailable:
                status(icon: "wifi.slash") {
                    Text("This app isn't reachable right now")
                        .font(.headline)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text("It runs on its owner's machine. It'll appear when that machine is online and sharing.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
            case .failed(let message):
                status(icon: "exclamationmark.triangle") {
                    Text("Couldn't open \(model.clawName)")
                        .font(.headline)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
            }
        }
        .navigationTitle(model.clawName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.resolve() }
    }

    @ViewBuilder
    private func status<Content: View>(
        icon: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundColor(SoyehtTheme.textTertiary)
            }
            content()
        }
        .padding(32)
    }
}

/// Chrome around a shared app: a way back, and a marker that what is on screen
/// is someone else's machine, not this one. Mirrors
/// `RelayStreamTerminalContainerView` so a shared app and a shared terminal
/// present the same way.
struct ClawSiteContainerView: View {
    @ObservedObject var model: ClawSiteViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }

                Text(model.clawName)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(verbatim: "[shared app]")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ClawSiteView(model: model)
        }
        .background(SoyehtTheme.bgPrimary)
    }
}

#if DEBUG
struct ClawSiteView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ClawSiteView(
                model: ClawSiteViewModel(
                    clawName: "House finances",
                    provider: UnavailableClawSiteEndpointProvider()
                )
            )
        }
    }
}
#endif
