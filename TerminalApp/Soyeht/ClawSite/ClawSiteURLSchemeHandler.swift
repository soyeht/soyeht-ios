import Foundation
import SoyehtCore
import WebKit

/// Serves a shared claw's app to a `WKWebView` by carrying each request over
/// the relay-stream tunnel.
///
/// **Why a custom scheme and not a loopback HTTP server.** The obvious way to
/// feed a web view is to run a local listener and point it at
/// `http://127.0.0.1:<port>/`. On iOS that port is reachable by any other app
/// on the device, which would expose someone else's private shared app to every
/// process on the phone. A `WKURLSchemeHandler` opens no socket at all: WebKit
/// hands requests straight to this object, so the only reachable surface is the
/// web view we created.
///
/// The trade-off is honest and worth stating: a `clawsite://` origin is not an
/// `https://` origin, so a shared app that hard-codes absolute `http(s)://`
/// URLs to itself, or depends on secure-context-only web APIs, will not work.
/// Relative links, which is what an ordinary page uses, do.
final class ClawSiteURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "clawsite"
    static let host = "app"

    /// The URL a web view should load to reach the shared app's root.
    ///
    /// Composed through `URLComponents` rather than interpolated into a string:
    /// hand-assembling `scheme://host/` is the shape `EndpointPolicyTests`
    /// bans across production sources, and it is the worse construction anyway.
    /// This is a fixed in-process scheme, not a network endpoint, so it carries
    /// no host/port/TLS policy that would belong in `EndpointPolicy`.
    static var rootURL: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/"
        // Force-unwrap is safe for these constants; a nil here would be a
        // programming error in the literals above, not bad input.
        guard let url = components.url else {
            preconditionFailure("ClawSite root URL components are not well-formed")
        }
        return url
    }

    private let bridge: ClawSiteHTTPBridge
    /// `WKURLSchemeTask` throws an Objective-C exception — not a Swift error —
    /// if a callback arrives after `stop`. That is uncatchable and crashes the
    /// app, so tasks are tracked and every callback is gated on still being
    /// live. This is the reason the class holds a lock at all.
    private let lock = NSLock()
    private var liveTasks: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    /// Direct typed channel to the same failure handler the WKWebView's
    /// `WKNavigationDelegate` reports to (see `ClawSiteWebView.makeUIView`).
    /// Exists because crossing back out through WebKit's own ObjC/NSError
    /// bridging is not something this code can verify preserves the
    /// original Swift error — this handler hands it over directly instead,
    /// before WebKit gets a chance to translate or lose it. The delegate
    /// path stays as a fallback for failures WebKit originates outside any
    /// scheme task.
    ///
    /// Written on the main thread (`ClawSiteWebView.makeUIView`/
    /// `updateUIView`), read/invoked from `fail(_:with:)`, which runs inside
    /// this handler's own `Task { [bridge] in ... }` and can resume on any
    /// executor — the same class of hazard `liveTasks` already needed a lock
    /// for. No raw settable `var` in the public surface: only the
    /// lock-guarded setter below.
    private var typedFailureHandler: (@Sendable (Error) -> Void)?

    init(bridge: ClawSiteHTTPBridge) {
        self.bridge = bridge
        super.init()
    }

    /// Install the direct failure channel. Must be called before the web
    /// view this handler is registered on calls `load(...)`, so no early
    /// request can fail before a listener exists.
    func setTypedFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        typedFailureHandler = handler
        lock.unlock()
    }

    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        start(urlSchemeTask)
    }

    /// Starts one scheme task without requiring a live WebKit process.
    ///
    /// `WKWebView` is only the protocol callback carrier; none of the request
    /// handling depends on it. Keeping the work in this method lets focused
    /// tests exercise the real task lifecycle without launching WebKit's GPU
    /// process, whose startup latency is unrelated to this contract.
    func start(_ urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        liveTasks[key] = urlSchemeTask
        lock.unlock()

        let request = urlSchemeTask.request
        let url = request.url ?? Self.rootURL
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        let body = request.httpBody
        let path = Self.requestPath(from: url)

        Task { [bridge] in
            do {
                let response = try await bridge.perform(
                    method: method,
                    path: path,
                    headers: headers,
                    body: body
                )
                let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: response.statusCode,
                    httpVersion: response.httpVersion,
                    headerFields: response.headerFields
                )
                guard let httpResponse else {
                    self.fail(key, with: ClawSiteBridgeError.streamFailed("response not representable"))
                    return
                }
                self.finish(key, response: httpResponse, body: response.body)
            } catch {
                self.fail(key, with: error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.lock()
        liveTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    /// Path + query exactly as an origin server would see it on the request
    /// line. The custom scheme's host is ours and carries no meaning to the
    /// claw, so it is dropped here rather than leaking into `Host:`.
    static func requestPath(from url: URL) -> String {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        return path
    }

    private func claim(_ key: ObjectIdentifier) -> (any WKURLSchemeTask)? {
        lock.lock()
        defer { lock.unlock() }
        return liveTasks.removeValue(forKey: key)
    }

    private func finish(_ key: ObjectIdentifier, response: HTTPURLResponse, body: Data) {
        guard let task = claim(key) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private func fail(_ key: ObjectIdentifier, with error: Error) {
        guard let task = claim(key) else { return }
        lock.lock()
        let handler = typedFailureHandler
        lock.unlock()
        // Invoked OUTSIDE the lock: `NSLock` is not reentrant, and this
        // callback ultimately reaches `ClawSiteViewModel.reportLoadFailure`
        // — code this class does not control — so calling it while still
        // holding the lock is a real deadlock risk if anything downstream
        // ever re-enters this handler.
        handler?(error)
        task.didFailWithError(error)
    }
}
