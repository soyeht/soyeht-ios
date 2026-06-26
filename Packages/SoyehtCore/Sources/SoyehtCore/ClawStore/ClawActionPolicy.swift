import Foundation

/// Single, pure authority for "which Claw action is available, and why".
///
/// This is the unified decision policy (improvement plan P1.1). It folds the
/// three rules that previously lived in separate places - install/retry/deploy/
/// uninstall **visibility** (`ClawDetailActionAvailability`, detail-only) and
/// install **eligibility** (`MacClawInstallDecision`, card/drawer-only) - plus a
/// rule neither expressed: per-action **enablement** while another action is in
/// flight (today hand-rolled as `.disabled(viewModel.isPerformingAction)` in
/// both detail views and as a de-dup guard in the drawer).
///
/// PR-1 scope: this type + its tests + `ClawDetailActionAvailability` reduced to
/// a facade over it. No view, ViewModel, or `MacClawInstallDecision` change yet -
/// `actionInFlight`, `openTerminal`, `mayIssueInstall`, and `installBlockedReason`
/// are defined here but are not consumed until later slices (PR-2/PR-3/PR-4).
///
/// Purity contract: Foundation-only, `Sendable`/`Equatable`, no AppKit/SwiftUI/
/// Combine. Guest-image readiness enters as a plain `Bool` (`hostAllowsInstall`)
/// so the policy never imports the iOS observer or the macOS gate type - that
/// keeps it unit-testable from the AppKit-free `SoyehtMacDomain` mirror.
///
/// Rule table (rows are `installState`; readiness/installability/in-flight are
/// modifiers):
///   - `installability == .unavailable` HIDES install/retry (reason
///     `.notInstallable`); it never gates deploy or uninstall.
///   - `hostAllowsInstall == false` keeps install/retry/deploy VISIBLE but
///     disabled (reason `.hostNotReady`); it never gates uninstall.
///   - `actionInFlight == true` keeps shown actions visible but disabled
///     (reason `.actionInFlight`); it never gates uninstall visibility.
///   - `.notInstalled` -> install. `.installFailed` -> retryInstall.
///   - `.installed` -> deploy (iff `supportsDeploy`), openTerminal (rides on
///     deploy visibility, enabled iff `canOpenTerminal` and not in flight),
///     uninstall (always visible). `.installedButBlocked` -> uninstall only.
///   - `.installing`/`.uninstalling` -> `transient` indicator, no actions.
///   - `.unknown` -> `showsUnknownState`, no actions.
///   - `deployUnavailableReason` mirrors the legacy notice rule exactly:
///     `!supportsDeploy && installState.isInstalled`.
public struct ClawActionPolicy: Equatable, Sendable {

    /// A user-issuable Claw action whose availability this policy governs.
    public enum Action: Hashable, Sendable, CaseIterable {
        case install
        case retryInstall
        case deploy
        case uninstall
        case openTerminal
    }

    /// Why an action is hidden or disabled. Drives user-facing copy so callers
    /// stop re-deriving the reason inline.
    public enum BlockReason: Equatable, Sendable {
        /// The action does not apply to this state (e.g. terminal closure not
        /// wired) - no user-actionable copy.
        case notApplicable
        /// The backend marked the claw not installable (theyos #88).
        case notInstallable(ClawUnavailableReasonCode, message: String?)
        /// Guest-image readiness gate is active on the host.
        case hostNotReady
        /// The selected target cannot host a deployable instance.
        case deployUnsupportedForTarget
        /// Another mutating action is already running.
        case actionInFlight
    }

    /// A passive in-progress indicator (no actions are offered in these states).
    public enum Transient: Equatable, Sendable {
        case installing
        case uninstalling
    }

    /// The full input the decision is a pure function of.
    public struct Input: Equatable, Sendable {
        public let installState: ClawInstallState
        public let installability: ClawInstallability
        /// Guest-image readiness verdict (`GuestImageReadinessGateState.allowsInstall`
        /// on iOS / `MacGuestImageGateState.allowsInstall` on macOS), flattened to
        /// a Bool so the policy stays platform-free.
        public let hostAllowsInstall: Bool
        /// Whether the resolved target carries a `CreateInstanceTarget`.
        public let supportsDeploy: Bool
        /// Whether a mutating Claw action is already in flight for this claw
        /// (`viewModel.isPerformingAction` / drawer `installingClaws`).
        public let actionInFlight: Bool
        /// Whether an attach/terminal entry point is wired for this claw.
        public let canOpenTerminal: Bool

        public init(
            installState: ClawInstallState,
            installability: ClawInstallability,
            hostAllowsInstall: Bool,
            supportsDeploy: Bool = true,
            actionInFlight: Bool = false,
            canOpenTerminal: Bool = false
        ) {
            self.installState = installState
            self.installability = installability
            self.hostAllowsInstall = hostAllowsInstall
            self.supportsDeploy = supportsDeploy
            self.actionInFlight = actionInFlight
            self.canOpenTerminal = canOpenTerminal
        }
    }

    /// The inputs this decision was computed from (kept for transparency/equality).
    public let input: Input

    /// Actions that should be shown (regardless of whether they are tappable).
    public let visibleActions: Set<Action>
    /// Actions that should be shown AND tappable.
    public let enabledActions: Set<Action>

    /// Passive in-progress indicator, if any.
    public let transient: Transient?
    /// The claw resolved to an unrecognized state (fail-soft passive label).
    public let showsUnknownState: Bool
    /// Non-nil when an installed claw's target cannot deploy - drives the inline
    /// "deploy unavailable" notice. Equals the legacy
    /// `!supportsDeploy && installState.isInstalled` rule.
    public let deployUnavailableReason: BlockReason?
    /// Single reason an install/retry could not be issued, independent of which
    /// state row is active - convenience for the install handlers' message.
    public let installBlockedReason: BlockReason?

    private let blockReasons: [Action: BlockReason]

    public init(_ input: Input) {
        self.input = input

        let installable = input.installability.isInstallable
        let notInstallableReason: BlockReason? = {
            if case let .unavailable(code, message) = input.installability {
                return .notInstallable(code, message: message)
            }
            return nil
        }()

        var visible: Set<Action> = []
        var enabled: Set<Action> = []
        var reasons: [Action: BlockReason] = [:]
        var transientState: Transient?
        var unknown = false

        // install / retryInstall share one eligibility rule.
        func offerInstallLike(_ action: Action) {
            guard installable else {
                reasons[action] = notInstallableReason ?? .notApplicable
                return
            }
            visible.insert(action)
            if !input.hostAllowsInstall {
                reasons[action] = .hostNotReady
            } else if input.actionInFlight {
                reasons[action] = .actionInFlight
            } else {
                enabled.insert(action)
            }
        }

        switch input.installState {
        case .notInstalled:
            offerInstallLike(.install)

        case .installFailed:
            offerInstallLike(.retryInstall)

        case .installed:
            if input.supportsDeploy {
                visible.insert(.deploy)
                if !input.hostAllowsInstall {
                    reasons[.deploy] = .hostNotReady
                } else if input.actionInFlight {
                    reasons[.deploy] = .actionInFlight
                } else {
                    enabled.insert(.deploy)
                }
                // Open Terminal rides on deploy visibility. Its own gate is
                // whether an attach entry point was wired (`.notApplicable`
                // takes precedence - there is nothing to open), and like every
                // other shown action it is disabled while another action is in
                // flight.
                visible.insert(.openTerminal)
                if !input.canOpenTerminal {
                    reasons[.openTerminal] = .notApplicable
                } else if input.actionInFlight {
                    reasons[.openTerminal] = .actionInFlight
                } else {
                    enabled.insert(.openTerminal)
                }
            } else {
                reasons[.deploy] = .deployUnsupportedForTarget
            }
            visible.insert(.uninstall)
            if input.actionInFlight {
                reasons[.uninstall] = .actionInFlight
            } else {
                enabled.insert(.uninstall)
            }

        case .installedButBlocked:
            visible.insert(.uninstall)
            if input.actionInFlight {
                reasons[.uninstall] = .actionInFlight
            } else {
                enabled.insert(.uninstall)
            }

        case .installing:
            transientState = .installing

        case .uninstalling:
            transientState = .uninstalling

        case .unknown:
            unknown = true
        }

        self.visibleActions = visible
        self.enabledActions = enabled
        self.blockReasons = reasons
        self.transient = transientState
        self.showsUnknownState = unknown
        self.deployUnavailableReason =
            (!input.supportsDeploy && input.installState.isInstalled) ? .deployUnsupportedForTarget : nil
        self.installBlockedReason = {
            if !installable { return notInstallableReason ?? .notApplicable }
            if !input.hostAllowsInstall { return .hostNotReady }
            if input.actionInFlight { return .actionInFlight }
            return nil
        }()
    }

    public func isVisible(_ action: Action) -> Bool { visibleActions.contains(action) }
    public func isEnabled(_ action: Action) -> Bool { enabledActions.contains(action) }

    /// Why `action` is hidden or disabled, if it is not enabled.
    public func blockReason(for action: Action) -> BlockReason? { blockReasons[action] }

    /// Action-side gate for the install/retry handlers: may an install be issued
    /// at all? Backend installability + host readiness + a fresh-enough install
    /// state. Deliberately IGNORES `actionInFlight` - the caller owns in-flight
    /// de-duplication (matches `MacClawInstallDecision.shouldIssueInstall`).
    public var mayIssueInstall: Bool {
        guard input.installability.isInstallable, input.hostAllowsInstall else { return false }
        switch input.installState {
        case .notInstalled, .installFailed: return true
        default: return false
        }
    }
}
