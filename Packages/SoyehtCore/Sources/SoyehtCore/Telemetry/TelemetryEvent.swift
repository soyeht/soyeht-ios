import Foundation

/// Enumerated telemetry events — anonymous, no PII (FR-071).
/// `installFailed` and `firstPairFailed` carry an `InstallErrorClass`;
/// all other events carry no payload.
public enum TelemetryEvent: String, Codable, Sendable, CaseIterable {
    case installStarted
    case installCompleted
    case installFailed
    case firstPairCompleted
    case firstPairFailed
    case householdCreated
    case deviceAdded
    case carouselCompleted
}

/// Classification for `installFailed` / `firstPairFailed` — never expose raw
/// values to the user; for analytics backend only.
public enum InstallErrorClass: String, Codable, Sendable, CaseIterable {
    case noInternet
    case airdropFailed
    /// Log only when telemetry-relevant; never surface to the user.
    case appleIdMismatch
    case daemonBindFailed
    case keychainAclDenied
    case bonjourPublishTimeout
    case smappserviceFailed
    case diskFull
    case gatekeeperBlocked
    case userCancelled
}
