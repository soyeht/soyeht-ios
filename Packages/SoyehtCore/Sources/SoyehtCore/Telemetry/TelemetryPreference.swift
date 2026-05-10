import Foundation

/// Persistent opt-in flag for anonymous telemetry (default OFF per FR-073).
///
/// Backed by `UserDefaults`. iOS SwiftUI callers can mirror the `optIn` key via
/// `@AppStorage("telemetry_opt_in")` since `@AppStorage` reads the same
/// `UserDefaults.standard` store. The struct owns the authoritative read/write
/// path; SwiftUI bindings are view-level decoration only.
// UserDefaults is internally thread-safe; @unchecked Sendable is correct.
public struct TelemetryPreference: @unchecked Sendable {
    private let defaults: UserDefaults

    public static let optInKey = "telemetry_opt_in"
    public static let decidedAtKey = "telemetry_decided_at"
    public static let lastEventSentAtKey = "telemetry_last_event_sent_at"
    public static let dailySentCountKey = "telemetry_daily_sent_count"
    public static let dailyWindowEpochKey = "telemetry_daily_window_epoch"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the user has opted in. Default `false` (FR-073).
    public var optIn: Bool {
        get { defaults.bool(forKey: Self.optInKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.optInKey) }
    }

    /// Unix-second timestamp when the user first made a decision (opt-in or opt-out).
    /// `nil` at first launch (undecided).
    public var decidedAt: UInt64? {
        get {
            guard let n = defaults.object(forKey: Self.decidedAtKey) as? NSNumber else { return nil }
            return n.uint64Value
        }
        nonmutating set {
            if let v = newValue {
                defaults.set(NSNumber(value: v), forKey: Self.decidedAtKey)
            } else {
                defaults.removeObject(forKey: Self.decidedAtKey)
            }
        }
    }

    /// Unix-second timestamp of the most recently submitted event; `nil` if none sent yet.
    /// Used by `TelemetryClient` for rate-limit enforcement (≤1/min, 50/day).
    public var lastEventSentAt: UInt64? {
        get {
            guard let n = defaults.object(forKey: Self.lastEventSentAtKey) as? NSNumber else { return nil }
            return n.uint64Value
        }
        nonmutating set {
            if let v = newValue {
                defaults.set(NSNumber(value: v), forKey: Self.lastEventSentAtKey)
            } else {
                defaults.removeObject(forKey: Self.lastEventSentAtKey)
            }
        }
    }

    /// Number of events sent within the current daily window.
    public var dailySentCount: Int {
        get { defaults.integer(forKey: Self.dailySentCountKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.dailySentCountKey) }
    }

    /// Unix-second timestamp marking the start of the current 24-hour window.
    /// Zero means no window has been established yet.
    public var dailyWindowEpoch: UInt64 {
        get {
            guard let n = defaults.object(forKey: Self.dailyWindowEpochKey) as? NSNumber else { return 0 }
            return n.uint64Value
        }
        nonmutating set {
            defaults.set(NSNumber(value: newValue), forKey: Self.dailyWindowEpochKey)
        }
    }
}
