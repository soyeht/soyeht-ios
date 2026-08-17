import AppKit
import WebKit

/// Renders an installed app (Phase 2a): a local HTML/JS/CSS bundle served
/// from its own origin (`soyehtapp-<appID>://local/`) with ZERO
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

    private let record: AppInstallRecord
    private let schemeHandler: AppBundleSchemeHandler
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
        schemeHandler = try AppBundleSchemeHandler(bundleRoot: record.bundleRoot, appID: record.manifest.id)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// App-pane configuration factory. Kept deliberately separate from the
    /// Phase 1 web-pane configuration: different trust posture, different
    /// navigation policy, and — the control that matters — no message
    /// handler is ever added here.
    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Persistent store: the Phase 2a storage spike measured that
        // localStorage/IndexedDB DO persist for custom-scheme origins on
        // the shipping WebKit (result recorded in the PR). Without it an
        // editor could not keep its own settings.
        configuration.websiteDataStore = .default()
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: AppBundleSchemeHandler.scheme(for: record.manifest.id)
        )
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
        // Closing the pane revokes the bundle's file descriptor.
        schemeHandler.close()
    }

    private func loadEntry() {
        var components = URLComponents()
        components.scheme = AppBundleSchemeHandler.scheme(for: record.manifest.id)
        components.host = AppBundleSchemeHandler.host
        components.path = "/" + record.manifest.entry
        guard let url = components.url else { return }
        webView.load(URLRequest(url: url))
    }

    private func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        // Stricter than the Phase 1 web pane (sia's contract amendment): an
        // app pane is locked to its OWN scheme — it cannot become a browser.
        return url.scheme == AppBundleSchemeHandler.scheme(for: record.manifest.id)
    }

    // MARK: - WKNavigationDelegate

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
