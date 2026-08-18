import AppKit
import os
import WebKit

/// Renders an installed app (Phase 2a): a local HTML/JS/CSS bundle served
/// from its own origin (`soyehtapp-<installID>://local/`) with ZERO
/// capabilities — no bridge, no network (`connect-src 'none'` on every
/// response). An app pane can do *less* than a website.
///
/// This is NOT the Phase 1 web pane with a flag (contract §4): the two
/// configurations are built by separate factory functions, and this one
/// never installs a message handler — the ABSENCE of the handler is the
/// control, so there is no runtime branch that could be wrong. Phase 2b
/// adds the bridge to this configuration only.
@MainActor
final class AppPaneViewController: NSViewController, PaneContentViewControlling, WKNavigationDelegate, WKUIDelegate {
    let paneID: Conversation.ID
    let contentKind: PaneContentKind = .app
    private(set) var state: AppPaneState

    /// Navigation-lifecycle instrumentation (Phase 2a intermittent-render
    /// hunt): the next time a runtime-created pane paints black, these logs
    /// say whether the load completed (process alive, compositing fault) or
    /// never did (load/process fault) — mechanism instead of symptom.
    /// `webContentProcessDidTerminate` additionally reloads, which is both
    /// the standard recovery AND the remedy if the mechanism is WebContent
    /// death in long-lived processes.
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "app.pane")

    private let record: AppInstallRecord
    private let schemeHandler: AppBundleSchemeHandler
    private let bridgeHandler: AppCapabilityBridgeHandler
    private var webView: WKWebView!
    private var isTornDown = false

    var headerAccessories: PaneHeaderAccessories { .specialDefault }
    var matchingKey: String { PaneContent.app(state).matchingKey }
    /// Third-party data: plain text only (NSTextField renders no markup),
    /// scalar-capped at construction — see `AppPaneState`.
    var headerTitle: String {
        let name = state.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? record.manifest.id : name
    }
    var headerSubtitle: String? { record.manifest.id }

    enum AppPaneError: LocalizedError {
        case installNotFound(String)

        var errorDescription: String? {
            switch self {
            case .installNotFound(let id):
                return "App installation not found: \(id)"
            }
        }
    }

    init(paneID: Conversation.ID, state: AppPaneState) throws {
        guard let record = AppInstallStore.record(installID: state.installID) else {
            throw AppPaneError.installNotFound(state.installID)
        }
        self.paneID = paneID
        self.state = state
        self.record = record
        schemeHandler = try AppBundleSchemeHandler(bundleRoot: record.bundleRoot, origin: record.origin)
        bridgeHandler = AppCapabilityBridgeHandler(paneID: paneID, record: record)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// App-pane configuration factory. Kept deliberately separate from the
    /// Phase 1 web-pane configuration: different trust posture, different
    /// navigation policy, and — the control that matters — the capability
    /// bridge exists HERE and only here. The web pane never gains a handler.
    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Persistent store: the Phase 2a storage spike measured that
        // localStorage/IndexedDB DO persist for custom-scheme origins on
        // the shipping WebKit (result recorded in the PR). Without it an
        // editor could not keep its own settings.
        configuration.websiteDataStore = .default()
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: record.origin.scheme
        )
        // Phase 2b: the capability bridge — isolated world, relay, principal
        // validation and rate limiting all live in the handler.
        bridgeHandler.install(on: configuration)
        return configuration
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        webView = WKWebView(frame: .zero, configuration: makeConfiguration())
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        applyTheme()
        loadEntry()
    }

    func focusContent() {
        view.window?.makeFirstResponder(webView)
    }

    func applyTheme() {
        view.layer?.backgroundColor = MacTheme.paneBody.cgColor
    }

    func updateContent(_ content: PaneContent) {
        // Identity is the installation id, stable by construction; a same-key
        // update can only carry display data (e.g. a renamed install). Never
        // reload the app on a store echo.
        guard case .app(let incoming) = content,
              incoming.installID == state.installID else { return }
        state = incoming
    }

    func prepareForClose() {
        guard !isTornDown else { return }
        isTornDown = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        // Structural teardown: the bridge handler is REMOVED (a closed pane
        // cannot keep serving capability calls) and the bundle's file
        // descriptor is closed.
        bridgeHandler.tearDown()
        schemeHandler.close()
    }

    private func loadEntry() {
        var components = URLComponents()
        components.scheme = record.origin.scheme
        components.host = AppOrigin.host
        components.path = "/" + record.manifest.entry
        guard let url = components.url else { return }
        Self.logger.log("app_pane_load pane=\(self.paneID.uuidString, privacy: .public) url=\(url.absoluteString, privacy: .public) inWindow=\(self.webView.window != nil, privacy: .public) bounds=\(NSStringFromRect(self.webView.bounds), privacy: .public)")
        webView.load(URLRequest(url: url))
    }

    private func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        // Stricter than the Phase 1 web pane (sia's contract amendment): an
        // app pane is locked to its OWN scheme — it cannot become a browser.
        return url.scheme == record.origin.scheme
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Self.logger.log("app_pane_nav_start pane=\(self.paneID.uuidString, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Self.logger.log("app_pane_nav_commit pane=\(self.paneID.uuidString, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.logger.log("app_pane_nav_finish pane=\(self.paneID.uuidString, privacy: .public) bounds=\(NSStringFromRect(webView.bounds), privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("app_pane_nav_fail pane=\(self.paneID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("app_pane_nav_fail_provisional pane=\(self.paneID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.logger.error("app_pane_webcontent_terminated pane=\(self.paneID.uuidString, privacy: .public) — reloading")
        // Guarded against teardown: reloading a closed pane would reopen its
        // PathScope'd bundle behind the user's back.
        guard !isTornDown else { return }
        if webView.url != nil {
            webView.reload()
        } else {
            // Termination before the first commit leaves nothing to reload.
            loadEntry()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        guard allowsNavigation(to: navigationResponse.response.url), navigationResponse.canShowMIMEType else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // No window.open / target=_blank in an app pane (contract §4).
        nil
    }
}
