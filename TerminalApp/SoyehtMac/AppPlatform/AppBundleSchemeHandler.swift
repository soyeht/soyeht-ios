import Foundation
import WebKit

/// Serves an installed app's bundle to its pane over the app's own scheme
/// (`soyehtapp-<appID>://local/…`).
///
/// Phase 2a contract (`docs/app-identity-phase2a.md` §3): a per-app scheme
/// gives the app its own origin, so same-origin policy isolates apps from
/// each other for free, and lets us synthesize response headers (CSP).
///
/// Every requested path is **page-controlled input**, so resolution goes
/// exclusively through `PathScope` (kernel-imposed confinement) — never
/// string comparison, never `URL.path` + `FileManager`. Reads happen on the
/// returned descriptor.
///
/// Task lifecycle follows `ClawSiteURLSchemeHandler`: a `WKURLSchemeTask`
/// throws an uncatchable Objective-C exception if used after `stop`, so
/// tasks are tracked under a lock and every callback is gated on the task
/// still being live.
final class AppBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static func scheme(for appID: String) -> String { "soyehtapp-\(appID)" }
    static let host = "local"

    /// Phase 2a CSP (contract §3): `connect-src 'none'` is the control that
    /// makes an app structurally unable to exfiltrate — the frontier is what
    /// the app CAN do, never what it looks like it does. `script-src 'self'`
    /// bans remotely hosted code: reviewed code must be the executed code.
    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'"

    private let appID: String
    private let scope: PathScope
    private let lock = NSLock()
    private var liveTasks: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private var isClosed = false

    init(bundleRoot: URL, appID: String) throws {
        self.appID = appID
        scope = try PathScope(rootDirectory: bundleRoot)
    }

    /// Tears the scope down (pane closed). In-flight tasks are dropped from
    /// the live set so no callback touches them again; WebKit stops caring
    /// about them once the web view is gone.
    func close() {
        lock.lock()
        isClosed = true
        liveTasks.removeAll()
        lock.unlock()
        scope.close()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        liveTasks[id] = urlSchemeTask
        lock.unlock()

        serve(urlSchemeTask)

        lock.lock()
        liveTasks.removeValue(forKey: id)
        lock.unlock()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.lock()
        liveTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    // MARK: - Serving

    private func serve(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              url.scheme == Self.scheme(for: appID),
              url.host == Self.host else {
            fail(task, status: 400, reason: "malformed app bundle URL")
            return
        }

        // URL.path arrives percent-decoded; strip the leading slash to get
        // the scope-relative path. PathScope rejects anything dangerous.
        let relativePath = String(url.path.dropFirst(url.path.hasPrefix("/") ? 1 : 0))
        guard !relativePath.isEmpty else {
            fail(task, status: 404, reason: "no entry path")
            return
        }

        do {
            let fd = try scope.openFileForReading(relativePath: relativePath)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let data = try handle.readToEnd() ?? Data()
            respond(task, status: 200, contentType: Self.contentType(for: relativePath), body: data)
        } catch let error as PathScope.PathScopeError {
            switch error {
            case .notFound:
                fail(task, status: 404, reason: error.errorDescription ?? "not found")
            case .emptyPath, .emptyComponent, .absolutePath, .parentReference, .symlinkComponent, .escapesScope:
                // Confinement refusals are 403 and keep their distinguishable
                // reason — the app must be able to explain them to the user.
                fail(task, status: 403, reason: error.errorDescription ?? "forbidden")
            case .invalidRoot, .closed, .permissionDenied, .systemError:
                fail(task, status: 500, reason: error.errorDescription ?? "bundle error")
            }
        } catch {
            fail(task, status: 500, reason: "bundle read failed")
        }
    }

    private func respond(_ task: any WKURLSchemeTask, status: Int, contentType: String, body: Data) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": contentType,
                      "Content-Length": String(body.count),
                      "X-Content-Type-Options": "nosniff",
                      "Content-Security-Policy": Self.contentSecurityPolicy,
                  ]
              ) else {
            return
        }
        guard deliver(task, { $0.didReceive(response) }) else { return }
        guard deliver(task, { $0.didReceive(body) }) else { return }
        _ = deliver(task, { $0.didFinish() })
    }

    private func fail(_ task: any WKURLSchemeTask, status: Int, reason: String) {
        respond(task, status: status, contentType: "text/plain; charset=utf-8", body: Data(reason.utf8))
    }

    /// Gate every task callback on the task still being live — using a
    /// stopped task throws an uncatchable ObjC exception (see class doc).
    private func deliver(_ task: any WKURLSchemeTask, _ action: (any WKURLSchemeTask) throws -> Void) -> Bool {
        lock.lock()
        let live = !isClosed && liveTasks[ObjectIdentifier(task)] != nil
        lock.unlock()
        guard live else { return false }
        try? action(task)
        return true
    }

    private static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
