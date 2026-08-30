import Foundation

/// Decides whether a RUNNING engine process is stale relative to the engine
/// this app ships and requires.
///
/// The engine LaunchAgent outlives app updates by design (persistent panes),
/// and nothing ever compared the running process against the app's
/// expectation: on the owner's machine a single engine process served for
/// nine days across three app relaunches and one app update, and hosted the
/// degraded TCC state behind the 2026-08-28/29 silent-EPERM incident. This
/// policy is the decision half of the cure: at launch, an engine OLDER than
/// `EngineCompat.minSupportedEngineVersion` (which the release checker binds
/// to the shipped engine pin) justifies restarting the service.
///
/// Restarting a live engine destroys every brokered session, so the verdict
/// is deliberately conservative in both directions:
///  - only an engine provably OLDER than required is `stale`;
///  - a version that cannot be parsed on either side is `indeterminate`,
///    never `stale` — a probe failure must not read as permission to
///    destroy sessions (the same fail-closed rule the service installer
///    applies to its process probes).
///
/// Pure on purpose, mirroring `EngineServiceReconciler`: rules that decide
/// whether destruction is allowed have to be reachable by a test.
public enum EngineStalenessPolicy {

    public enum Verdict: Equatable, Sendable {
        /// Running engine satisfies the app's requirement — leave it alone.
        case fresh
        /// Running engine is older than the app requires — a restart is
        /// justified and the staged binary will serve the newer version.
        case stale
        /// One of the versions is unreadable — do nothing destructive.
        case indeterminate
    }

    public static func verdict(
        runningEngineVersion: String,
        expectedEngineVersion: String
    ) -> Verdict {
        guard EngineCompat.parseSemver(runningEngineVersion) != nil,
              EngineCompat.parseSemver(expectedEngineVersion) != nil else {
            return .indeterminate
        }
        let comparison = EngineCompat.compareSemver(
            runningEngineVersion, expectedEngineVersion
        )
        return comparison == .orderedAscending ? .stale : .fresh
    }
}
