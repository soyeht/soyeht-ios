import AppKit
import WebKit
import OSLog

@MainActor
final class WebPaneViewController: NSViewController, PaneContentViewControlling, WKNavigationDelegate, WKUIDelegate {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "web-pane.navigation")
    let paneID: Conversation.ID
    let contentKind: PaneContentKind = .web
    private(set) var state: WebPaneState

    var headerAccessories: PaneHeaderAccessories { .specialDefault }
    var matchingKey: String { PaneContent.web(state).matchingKey }
    var headerTitle: String {
        let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (host(for: state.url) ?? "web") : title
    }
    var headerSubtitle: String? { host(for: state.url) }

    private let urlField = NSTextField()
    private let backButton = WebPaneViewController.iconButton(
        systemName: "chevron.backward",
        toolTip: "Back"
    )
    private let forwardButton = WebPaneViewController.iconButton(
        systemName: "chevron.forward",
        toolTip: "Forward"
    )
    private let reloadButton = WebPaneViewController.iconButton(
        systemName: "arrow.clockwise",
        toolTip: "Reload"
    )
    private var webView: WKWebView!
    private var isTornDown = false

    init(paneID: Conversation.ID, state: WebPaneState) {
        self.paneID = paneID
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = makeToolbar()
        root.addSubview(toolbar)
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        applyTheme()
        urlField.stringValue = state.url
        updateNavigationControls()
        load(state.url)
    }

    func focusContent() {
        view.window?.makeFirstResponder(webView)
    }

    func applyTheme() {
        view.layer?.backgroundColor = MacTheme.paneBody.cgColor
        urlField.textColor = MacTheme.textPrimary
        urlField.backgroundColor = MacTheme.surfaceBase
        urlField.drawsBackground = true
    }

    func updateContent(_ content: PaneContent) {
        guard case .web(let incoming) = content else { return }

        // Store observation re-enters here after didFinish writes state. Do
        // not reload the same document: that would lose page history, scroll
        // position, and form state, and would create a write-back loop.
        if webView?.url?.absoluteString == incoming.url {
            return
        }

        state = incoming
        urlField.stringValue = incoming.url
        load(incoming.url)
    }

    func prepareForClose() {
        guard !isTornDown else { return }
        isTornDown = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
    }

    @objc private func backTapped() {
        webView.goBack()
    }

    @objc private func forwardTapped() {
        webView.goForward()
    }

    @objc private func reloadTapped() {
        webView.reload()
    }

    private func makeToolbar() -> NSView {
        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = MacTheme.paneHeaderNew.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [backButton, forwardButton, reloadButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.translatesAutoresizingMaskIntoConstraints = false

        urlField.placeholderString = "https://example.com"
        urlField.font = NSFont.systemFont(ofSize: 13)
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.target = self
        urlField.action = #selector(urlSubmitted)
        urlField.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(backTapped)
        forwardButton.target = self
        forwardButton.action = #selector(forwardTapped)
        reloadButton.target = self
        reloadButton.action = #selector(reloadTapped)

        toolbar.addSubview(controls)
        toolbar.addSubview(urlField)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            urlField.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 8),
            urlField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            urlField.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            urlField.heightAnchor.constraint(equalToConstant: 24),
        ])
        return toolbar
    }

    @objc private func urlSubmitted() {
        load(urlField.stringValue)
    }

    private func load(_ raw: String) {
        let normalized = WebURL.normalizeUserInput(raw)
        guard let url = try? WebURL.validate(normalized) else {
            NSSound.beep()
            urlField.stringValue = state.url
            return
        }
        webView.load(URLRequest(url: url))
    }

    private func updateNavigationControls() {
        backButton.isEnabled = webView?.canGoBack ?? false
        forwardButton.isEnabled = webView?.canGoForward ?? false
    }

    private func persistFinishedNavigation() {
        guard let url = webView.url,
              (try? WebURL.validate(url.absoluteString)) != nil else {
            return
        }

        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newState = WebPaneState(
            anchorURL: state.anchorURL,
            url: url.absoluteString,
            title: title?.isEmpty == false ? title : nil
        )
        guard newState != state else { return }

        // Set local state first. ConversationStore invalidates all pane
        // observers, which re-enters updateContent synchronously enough that
        // an old matching key here would tear the WKWebView down.
        state = newState
        urlField.stringValue = newState.url

        guard let store = AppEnvironment.conversationStore,
              let conversation = store.conversation(paneID),
              case .web(let storedState) = conversation.content,
              storedState != newState else {
            return
        }
        store.updateContent(paneID, content: .web(newState))
    }

    private func host(for raw: String) -> String? {
        URLComponents(string: raw)?.host
    }

    private func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        return (try? WebURL.validate(url.absoluteString)) != nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Self.logger.debug("navigation_started")
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Self.logger.debug("navigation_committed")
        if let url = webView.url, allowsNavigation(to: url) {
            urlField.stringValue = url.absoluteString
        }
        updateNavigationControls()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.logger.debug("navigation_finished")
        // WKWebView invokes this for its main-document navigation. The URL is
        // checked again so `about:blank` and any failed policy edge cannot be
        // persisted as pane state.
        persistFinishedNavigation()
        updateNavigationControls()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("navigation_failed error=\(error.localizedDescription, privacy: .public)")
        updateNavigationControls()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("navigation_provisional_failed error=\(error.localizedDescription, privacy: .public)")
        updateNavigationControls()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.logger.error("web_content_process_terminated")
        guard !isTornDown else { return }
        load(state.url)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard allowsNavigation(to: navigationAction.request.url) else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    private static func iconButton(systemName: String, toolTip: String) -> NSButton {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: toolTip)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}
