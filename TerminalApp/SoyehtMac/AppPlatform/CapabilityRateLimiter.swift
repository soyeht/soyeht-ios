import Foundation

/// Token-bucket rate limiter for capability calls (Phase 2b contract §3:
/// "limite de taxa por pane"). Pure domain type — no AppKit, testable in
/// the domain package.
///
/// One bucket per key (pane). A burst up to `capacity` is allowed, then
/// sustained use is capped at `refillPerSecond`. Fail-closed: a key that
/// has exhausted its bucket is refused until tokens refill.
struct CapabilityRateLimiter {
    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
    }

    let capacity: Int
    let refillPerSecond: Double

    private var buckets: [String: Bucket] = [:]

    init(capacity: Int, refillPerSecond: Double) {
        precondition(capacity > 0 && refillPerSecond > 0, "rate limiter needs positive capacity and refill")
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
    }

    /// Phase 2b default: metrics.read is a poll, not a stream — a 4-call
    /// burst, then one call per two seconds sustained.
    static let metricsDefault = CapabilityRateLimiter(capacity: 4, refillPerSecond: 0.5)

    mutating func allow(key: String, now: Date = Date()) -> Bool {
        var bucket = buckets[key] ?? Bucket(tokens: Double(capacity), lastRefill: now)
        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        if elapsed > 0 {
            bucket.tokens = min(Double(capacity), bucket.tokens + elapsed * refillPerSecond)
            bucket.lastRefill = now
        }
        guard bucket.tokens >= 1 else {
            buckets[key] = bucket
            return false
        }
        bucket.tokens -= 1
        buckets[key] = bucket
        return true
    }
}
