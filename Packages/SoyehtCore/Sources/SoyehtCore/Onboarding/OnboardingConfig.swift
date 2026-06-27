import Foundation

/// Centralized, read-only configuration for onboarding-phase timeouts.
///
/// Fase 2 single source of truth for the timing constants that are currently
/// hard-coded and scattered across the onboarding flow. This type is **inert**
/// in this slice: it defines the values and their validation only - no caller is
/// migrated yet, so it changes no runtime behavior. Each property documents the
/// site it will eventually replace so the later migration to `default` is a
/// provable no-op.
///
/// Scope note: this first cut carries only the non-build-conditional
/// onboarding-phase timeouts. The build-conditional pair-machine QR TTL
/// (`PairMachineQR`, DEBUG vs RELEASE), the bootstrap retry/backoff sequence
/// (`BootstrapStatusClient`), and the per-client network/Nostr timeouts are
/// deliberately deferred to later config slices to keep this PR minimal.
public struct OnboardingConfig: Sendable, Equatable {
    /// Delay before showing the "this is taking a while" hint during house-name
    /// submission.
    ///
    /// Source today: `HouseNamingFromiPhoneView.slowHintDelay` (`.seconds(5)`).
    public let houseNamingHintDelay: TimeInterval

    /// Deadline for the Mac auto-discovery retry loop before it gives up.
    ///
    /// Source today: `AwaitingMacView` discovery `deadline`
    /// (`Date().addingTimeInterval(60)`).
    public let macDiscoveryDeadline: TimeInterval

    /// Delay before surfacing the manual-recovery hint while awaiting a Mac.
    ///
    /// Source today: `AwaitingMacView.recoveryHintDelaySeconds` (`20`).
    public let macDiscoveryRecoveryHintDelay: TimeInterval

    /// Per-request timeout for a single Mac-discovery probe.
    ///
    /// Source today: `AwaitingMacView` probe `timeoutInterval` /
    /// `timeoutIntervalForRequest` (`2.0`).
    public let macProbeTimeout: TimeInterval

    /// Timeout for resolving the first matching household candidate from a QR.
    ///
    /// Source today:
    /// `HouseholdPairingService.firstMatchingCandidate(for:timeout:)` (`10`).
    public let householdDiscoveryTimeout: TimeInterval

    public init(
        houseNamingHintDelay: TimeInterval = 5,
        macDiscoveryDeadline: TimeInterval = 60,
        macDiscoveryRecoveryHintDelay: TimeInterval = 20,
        macProbeTimeout: TimeInterval = 2,
        householdDiscoveryTimeout: TimeInterval = 10
    ) {
        self.houseNamingHintDelay = houseNamingHintDelay
        self.macDiscoveryDeadline = macDiscoveryDeadline
        self.macDiscoveryRecoveryHintDelay = macDiscoveryRecoveryHintDelay
        self.macProbeTimeout = macProbeTimeout
        self.householdDiscoveryTimeout = householdDiscoveryTimeout
    }

    /// The canonical defaults, matching the values currently hard-coded at each
    /// onboarding site - so migrating a caller to `OnboardingConfig.default` is
    /// behavior-preserving.
    public static let `default` = OnboardingConfig()

    /// A validation failure for an onboarding timeout.
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        /// A timeout was zero or negative; all onboarding timeouts must be > 0.
        case nonPositive(field: String, value: TimeInterval)

        public var description: String {
            switch self {
            case let .nonPositive(field, value):
                return "OnboardingConfig.\(field) must be > 0, got \(value)"
            }
        }
    }

    /// Validates that every timeout is strictly positive. Callers that build a
    /// config from external input (feature flags, overrides) should call this
    /// before use. `OnboardingConfig.default` is valid by construction.
    public func validate() throws {
        let fields: [(String, TimeInterval)] = [
            ("houseNamingHintDelay", houseNamingHintDelay),
            ("macDiscoveryDeadline", macDiscoveryDeadline),
            ("macDiscoveryRecoveryHintDelay", macDiscoveryRecoveryHintDelay),
            ("macProbeTimeout", macProbeTimeout),
            ("householdDiscoveryTimeout", householdDiscoveryTimeout),
        ]
        for (name, value) in fields where value <= 0 {
            throw ValidationError.nonPositive(field: name, value: value)
        }
    }
}
