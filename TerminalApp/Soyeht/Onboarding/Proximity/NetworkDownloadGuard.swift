import Foundation
import Network
import UIKit
import SoyehtCore

/// Pre-flight checks before AirDrop transfer/download (FR-123, FR-124).
///
/// Checks:
///   - FR-123: Whether the active network path is cellular-only.
///   - FR-124: Whether battery level is below 20% (and device is not charging).
///
/// Returns a `Condition` set that the caller uses to decide which confirmation
/// sheet to surface. Default highlighted action is the conservative path (FR-119).
public final class NetworkDownloadGuard: @unchecked Sendable {
    public enum Condition: Sendable {
        case cellular
        case lowBattery
    }

    public struct PreflightResult: Sendable {
        public let conditions: [Condition]
        public var requiresConfirmation: Bool { !conditions.isEmpty }
    }

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.soyeht.network-download-guard")

    public init() {
        monitor = NWPathMonitor()
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    deinit {
        monitor.cancel()
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    /// Performs a one-shot pre-flight check and returns the result.
    public func check() async -> PreflightResult {
        let path = await currentPath()
        var conditions: [Condition] = []

        if isCellularOnly(path) {
            conditions.append(.cellular)
        }

        if isLowBattery() {
            conditions.append(.lowBattery)
        }

        return PreflightResult(conditions: conditions)
    }

    // MARK: - Private

    private func currentPath() async -> NWPath {
        final class Box: @unchecked Sendable { var resumed = false }
        let box = Box()
        return await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                guard !box.resumed else { return }
                box.resumed = true
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
        }
    }

    private func isCellularOnly(_ path: NWPath) -> Bool {
        path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
    }

    private func isLowBattery() -> Bool {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        // -1.0 means monitoring unavailable; treat as safe.
        guard level >= 0 else { return false }
        let notCharging = state == .unplugged || state == .unknown
        return notCharging && level < 0.20
    }
}
