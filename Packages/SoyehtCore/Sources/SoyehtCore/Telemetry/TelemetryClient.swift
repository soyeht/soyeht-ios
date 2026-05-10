import Foundation

/// Opt-in-gated anonymous event submitter (FR-073, research R12).
///
/// - Gates all sends on `TelemetryPreference.optIn`.
/// - Queues events persistently (JSON in Application Support) with a 1000-event
///   cap; oldest events are evicted on overflow.
/// - Rate-limits to ≤1 send/minute and ≤50 sends/day.
/// - Targets `https://telemetry.soyeht.com/event` (T150); tolerates endpoint
///   absence silently — failures never surface to the UX.
public final class TelemetryClient: @unchecked Sendable {
    public static let endpoint = URL(string: "https://telemetry.soyeht.com/event")!
    static let maxQueueSize = 1_000
    static let maxPerMinute = 1
    static let maxPerDay = 50

    private let preference: TelemetryPreference
    private let appVersion: String
    private let platform: String
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let queue = DispatchQueue(label: "com.soyeht.telemetry")
    private let storeURL: URL

    public convenience init(
        preference: TelemetryPreference = TelemetryPreference(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    ) {
        self.init(
            preference: preference,
            appVersion: appVersion,
            transport: { req in try await URLSession.shared.data(for: req) }
        )
    }

    init(
        preference: TelemetryPreference,
        appVersion: String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.preference = preference
        self.appVersion = appVersion
        self.transport = transport
        #if os(macOS)
        self.platform = "mac"
        #else
        self.platform = "ios"
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.storeURL = (appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Soyeht")
            .appendingPathComponent("telemetry-queue.json")
    }

    /// Enqueues an event. No-ops if opt-in is false.
    public func track(_ event: TelemetryEvent, errorClass: InstallErrorClass? = nil) {
        guard preference.optIn else { return }
        queue.async {
            self.enqueue(event, errorClass: errorClass)
            Task { await self.flush() }
        }
    }

    // MARK: - Private

    private func enqueue(_ event: TelemetryEvent, errorClass: InstallErrorClass?) {
        var q = loadQueue()
        let now = UInt64(Date().timeIntervalSince1970)
        var entry: [String: String] = [
            "event": event.rawValue,
            "timestamp": String(now),
            "version": appVersion,
            "platform": platform,
        ]
        if let ec = errorClass { entry["error_class"] = ec.rawValue }
        q.append(entry)
        if q.count > Self.maxQueueSize {
            q = Array(q.suffix(Self.maxQueueSize))
        }
        saveQueue(q)
    }

    private func flush() async {
        guard preference.optIn else { return }
        guard !isRateLimited() else { return }

        let nextEntry: [String: String]? = queue.sync {
            var q = self.loadQueue()
            guard !q.isEmpty else { return nil }
            let e = q.removeFirst()
            self.saveQueue(q)
            return e
        }
        guard let payload = nextEntry else { return }

        do {
            try await send(payload)
            queue.sync { self.recordSend() }
        } catch {
            // Silently drop failures — re-queue on next flush
            queue.sync {
                var q = self.loadQueue()
                q.insert(payload, at: 0)
                if q.count > Self.maxQueueSize { q = Array(q.suffix(Self.maxQueueSize)) }
                self.saveQueue(q)
            }
        }
    }

    private func isRateLimited() -> Bool {
        queue.sync {
            let now = UInt64(Date().timeIntervalSince1970)
            let pref = preference
            // ≤1/minute
            if let last = pref.lastEventSentAt, now - last < 60 { return true }
            // ≤50/day — treat expired window as zero count
            let windowActive = pref.dailyWindowEpoch > 0 && now < pref.dailyWindowEpoch + 86_400
            let countToday = windowActive ? pref.dailySentCount : 0
            return countToday >= Self.maxPerDay
        }
    }

    private func recordSend() {
        let now = UInt64(Date().timeIntervalSince1970)
        preference.lastEventSentAt = now
        if preference.dailyWindowEpoch == 0 || now >= preference.dailyWindowEpoch + 86_400 {
            preference.dailyWindowEpoch = now - (now % 86_400)
            preference.dailySentCount = 1
        } else {
            preference.dailySentCount += 1
        }
    }

    private func send(_ entry: [String: String]) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 8
        _ = try await transport(req)
    }

    // MARK: - Persistence

    private func loadQueue() -> [[String: String]] {
        guard let data = try? Data(contentsOf: storeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return json
    }

    private func saveQueue(_ q: [[String: String]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: q) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}
