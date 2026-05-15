import Foundation

/// Abstracts the iOS ActivityKit-backed Live Activity so `ClawDeployMonitor`
/// can live in SoyehtCore without dragging ActivityKit into macOS. iOS
/// provides a concrete adapter that forwards to `Activity<ClawDeployAttributes>`;
/// macOS uses the built-in no-op for now (can later be replaced with a Dock
/// badge / status-item variant without changing the monitor).
public protocol ClawDeployActivityManaging: AnyObject, Sendable {
    /// Called once per deploy, immediately after the instance is created.
    func startActivity(
        instanceId: String,
        clawName: String,
        clawType: String,
        cpuCores: Int,
        ramMB: Int,
        diskGB: Int
    )

    /// Called each time the monitor polls a new status/phase from the server.
    func updateActivity(status: String, message: String?, phase: String?)

    /// Called once the deploy reaches a terminal state (active or failed).
    func endActivity(status: String, message: String?)
}

/// Default implementation that does nothing. macOS uses this today; iOS
/// substitutes a real ActivityKit-backed adapter.
public final class NoOpClawDeployActivityManager: ClawDeployActivityManaging, @unchecked Sendable {
    public init() {}
    public func startActivity(instanceId: String, clawName: String, clawType: String, cpuCores: Int, ramMB: Int, diskGB: Int) {}
    public func updateActivity(status: String, message: String?, phase: String?) {}
    public func endActivity(status: String, message: String?) {}
}
