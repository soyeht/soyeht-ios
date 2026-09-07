import Foundation
import SoyehtCore

/// Bounded authenticated readback for the local installation, including before
/// the app has a household session. No remote server selection or keychain
/// fallback participates. The bootstrap credential never enters argv or logs.
enum EngineRuntimeReadback {
    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var value: EngineRuntimeIdentity?
        func store(_ result: EngineRuntimeIdentity?) {
            lock.lock(); defer { lock.unlock() }
            value = result
        }
        func read() -> EngineRuntimeIdentity? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    static func request(profile: SoyehtInstallProfile, token: String) -> URLRequest? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: "http://127.0.0.1:\(profile.adminPort)/api/v1/version") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Called only from a lifecycle worker. Timeout, unreadable credentials,
    /// redirects and malformed responses are unknown, never a legacy identity.
    static func read(profile: SoyehtInstallProfile, tokenURL: URL) -> EngineRuntimeIdentity? {
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8),
              let request = request(profile: profile, token: token) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil, let response = response as? HTTPURLResponse,
                  response.statusCode == 200, let data, data.count <= 65_536,
                  let runtime = try? JSONDecoder().decode(EngineRuntimeIdentity.self, from: data) else { return }
            reply.store(runtime)
        }
        task.resume()
        guard done.wait(timeout: .now() + 7) == .success else {
            task.cancel()
            return nil
        }
        return reply.read()
    }
}
