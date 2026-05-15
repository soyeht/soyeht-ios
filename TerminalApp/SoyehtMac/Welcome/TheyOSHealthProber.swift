import Foundation

/// Polls `http://localhost:8892/health` until it returns 2xx or the deadline
/// expires. Used after `soyeht start` to confirm the admin backend is ready
/// before kicking off the auto-pair flow.
actor TheyOSHealthProber {
    private let url: URL
    private let session: URLSession

    init(url: URL = TheyOSEnvironment.healthURL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    /// Returns `true` once the server responds with 2xx. Returns `false` if
    /// the timeout elapses first. Polls every second with a short per-request
    /// timeout so cancellation is responsive.
    func waitForHealthy(timeout seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if await probeOnce() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private func probeOnce() async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
