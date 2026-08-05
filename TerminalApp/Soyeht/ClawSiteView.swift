import SwiftUI
import WebKit
import SoyehtCore
import os

/// Diagnostic-only sink for raw WebKit load errors. Plan §5.4: "Raw
/// localizedDescription is diagnostics-only" — logged for support/debugging,
/// never rendered in the guest-facing UI.
private let clawSiteLoadLogger = Logger(subsystem: "com.soyeht.mobile", category: "claw-site-load")

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
/// The signed offer's Device+ClawSite audience selects the engine's Device
/// app resolver (4B-2-3), which resolves the household-scoped D6 binding
/// and connects to that app's own validated backend loopback port — there
/// is no global/env-configured backend anymore. This provider only reuses
/// the offer+credential this device already claimed; it never itself picks
/// a backend, that routing decision is entirely server-side.
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
        case failed(ClawShareOpenFailure)

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

    /// The raw error is logged (diagnostics-only, §5.4) and never stored in
    /// `phase` — only its stable classification is, so nothing technical can
    /// reach the view.
    ///
    /// Dedupe: the direct typed channel (`ClawSiteURLSchemeHandler
    /// .setTypedFailureHandler`) and the `WKNavigationDelegate` fallback can
    /// both report the SAME failure, in either order. Whichever arrives
    /// first moves `phase` off `.ready`; the guard below makes the second
    /// call a no-op instead of reclassifying (possibly with a less precise
    /// answer, if it's the WebKit-translated fallback).
    func reportLoadFailure(_ error: Error) {
        guard case .ready = phase else { return }
        clawSiteLoadLogger.error("ClawSite load failed: \(error.localizedDescription, privacy: .private)")
        if ClawShareOpenFailure.isRecoverableAppUnavailable(error) {
            // D1: not a failure at all — the shared app isn't running right
            // now, and this resolves itself once it is. Same recoverable
            // phase `resolve()` already uses for "no source at all."
            phase = .unavailable
            return
        }
        phase = .failed(ClawShareOpenFailure.classify(error))
    }

    /// Retry for the guest-facing load-failure screen: re-resolves the
    /// source and, for a `.ready` source, the web view reloads because the
    /// Coordinator has never marked ITS handler loaded before.
    func retry() async {
        await resolve()
    }
}

/// Whether `ClawSiteWebView.updateUIView` should reload for
/// `requestedHandler`, given what the Coordinator last marked as loaded.
///
/// Extracted as a pure, `Context`-free function so the DECISION itself is
/// unit tested directly — `UIViewRepresentable.Context` has no public
/// initializer (SwiftUI vends it only from a real, running view hierarchy),
/// so `updateUIView` itself cannot be called from a plain XCTest; this is
/// therefore a policy-unit test, not a callsite/integration test. Nothing
/// here proves what `updateUIView` does with the answer, only that the
/// answer itself is correct for the two cases that matter.
enum ClawSiteWebViewReloadPolicy {
    /// Deliberately ignores where `webView.url` currently points — that
    /// drifts on every valid in-page navigation the guest makes, and
    /// reloading because of it would discard their navigation and state
    /// (§5.4). Only the SOURCE's identity (a different claimed session)
    /// matters: same handler, whatever the guest has navigated to since →
    /// `false`; a genuinely different (or no) handler → `true`.
    static func shouldReload(
        loadedHandler: ClawSiteURLSchemeHandler?,
        requestedHandler: ClawSiteURLSchemeHandler
    ) -> Bool {
        loadedHandler !== requestedHandler
    }
}

/// `WKWebView` host. The claw's app is ordinary HTML served by the claw itself,
/// so it renders exactly as its author wrote it — any language, any framework.
///
/// Not `private`: `ClawSiteWebViewReloadPolicy` and `Coordinator` are unit
/// tested directly (`@testable import Soyeht`).
struct ClawSiteWebView: UIViewRepresentable {
    let source: ClawSiteSource
    let onFailure: @Sendable (Error) -> Void

    private var url: URL { source.url }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The claw's site is private to the invited guest; keep nothing behind.
        configuration.websiteDataStore = .nonPersistent()
        // Must be registered before the web view is constructed — WebKit reads
        // the handler table at init and ignores later additions.
        configuration.setURLSchemeHandler(source.handler, forURLScheme: ClawSiteURLSchemeHandler.scheme)
        // The direct typed channel — see `ClawSiteURLSchemeHandler
        // .typedFailureHandler`'s doc. This is the call site that actually
        // matters: the unavailable→retry cycle always passes through
        // `.resolving` first (a different `ClawSiteView.body` switch case),
        // which tears this whole `ClawSiteWebView` down, so every retry
        // reaches THIS `makeUIView`, never `updateUIView`, on a fresh
        // `WKWebView`/handler pair.
        source.handler.setTypedFailureHandler(onFailure)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        context.coordinator.markLoaded(source.handler)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        // Defensive only — NOT proof the retry path re-wires the channel.
        // `WKWebViewConfiguration.setURLSchemeHandler` is read once, at the
        // existing `webView`'s own construction; a handler installed here
        // is never consulted by THIS webview regardless. Kept in case some
        // future in-`.ready` update path legitimately reuses the same
        // already-registered handler.
        source.handler.setTypedFailureHandler(onFailure)
        guard ClawSiteWebViewReloadPolicy.shouldReload(
            loadedHandler: context.coordinator.loadedHandler,
            requestedHandler: source.handler
        ) else { return }
        webView.load(URLRequest(url: url))
        context.coordinator.markLoaded(source.handler)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onFailure: @Sendable (Error) -> Void
        // A STRONG reference, not just an `ObjectIdentifier`: an identifier
        // alone is only unique among currently-live objects — once the
        // handler it named is deallocated, a later, genuinely different
        // handler can be allocated at the same address and collide with it.
        // Holding the reference keeps the one we compared against alive for
        // as long as it is "the loaded one," so `===` (inside the policy
        // above) is always sound.
        private(set) var loadedHandler: ClawSiteURLSchemeHandler?

        init(onFailure: @escaping @Sendable (Error) -> Void) {
            self.onFailure = onFailure
        }

        func markLoaded(_ handler: ClawSiteURLSchemeHandler) {
            loadedHandler = handler
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            onFailure(error)
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError error: Error
        ) {
            onFailure(error)
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
                // `[weak model]`: `source.handler.onTypedFailure` (wired in
                // `ClawSiteWebView.makeUIView`) holds this SAME closure, and
                // `source` itself lives inside `model.phase` — a strong
                // capture here would cycle model → phase → source → handler
                // → closure → model.
                ClawSiteWebView(source: source) { [weak model] error in
                    model?.reportLoadFailure(error)
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
                    Button("Retry") { Task { await model.retry() } }
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.accentGreen)
                        .padding(.top, 6)
                }
            case .failed(let failure):
                status(icon: "exclamationmark.triangle") {
                    Text(failure.title)
                        .font(.headline)
                        .foregroundColor(SoyehtTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(failure.message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundColor(SoyehtTheme.textSecondary)
                    if failure.nextAction == .retry {
                        Button("Retry") { Task { await model.retry() } }
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.accentGreen)
                            .padding(.top, 6)
                    }
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
        .accessibilityElement(children: .combine)
    }
}

/// Chrome around a shared app: a way back, and the app's own name — no
/// transport vocabulary (host, VM, relay). Mirrors
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
