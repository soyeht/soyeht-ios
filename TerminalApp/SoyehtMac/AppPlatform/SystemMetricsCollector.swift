import Darwin
import Foundation

/// Phase 2b contract §3 — `metrics.read`, deliberately poor.
///
/// SYSTEM AGGREGATE ONLY: CPU load, used/free memory, uptime. Deliberately
/// OUT (by contract, not omission): process list, process names, hostname,
/// paths, network interfaces, serial number. A process list doesn't touch
/// disk but reveals which programs a person runs — that is information
/// disclosure, not machine measurement.
///
/// Values are QUANTIZED to whole units on purpose: the result must not let
/// an app infer other apps' activity with clock precision. Percentages are
/// integers, memory is whole MiB, uptime is whole seconds — combined with
/// the bridge's per-pane rate limit, there is no high-resolution timeline
/// to reconstruct.
struct SystemMetricsSnapshot: Codable, Hashable {
    /// Normalized system load (0–100): load average over logical cores,
    /// clamped. NOT instantaneous CPU usage — a load average is a smoother
    /// system aggregate and needs no sampling state.
    let cpuLoadPercent: Int
    /// Used memory in whole MiB (total − free − inactive).
    let memoryUsedMiB: Int64
    /// Available memory in whole MiB (free + inactive).
    let memoryFreeMiB: Int64
    /// Seconds since boot, whole seconds.
    let uptimeSeconds: Int64
}

/// Collects the system aggregate for `metrics.read`. New code — the repo
/// had no metrics collector before this phase.
enum SystemMetricsCollector {

    static func snapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpuLoadPercent: normalizedLoadPercent(),
            memoryUsedMiB: usedMemoryMiB(),
            memoryFreeMiB: freeMemoryMiB(),
            uptimeSeconds: uptimeSeconds()
        )
    }

    // MARK: - CPU

    private static func normalizedLoadPercent() -> Int {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 0, load[0] >= 0 else { return 0 }
        let cores = Double(logicalCoreCount())
        guard cores > 0 else { return 0 }
        let percent = (load[0] / cores) * 100.0
        return Int(percent.rounded())
    }

    private static func logicalCoreCount() -> Int32 {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &count, &size, nil, 0)
        return count > 0 ? count : 1
    }

    // MARK: - Memory

    private static func totalMemoryBytes() -> UInt64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        return total
    }

    /// free + inactive pages, in whole MiB. Inactive memory is reclaimable
    /// on demand — reporting it as "used" would be dishonest to the app.
    private static func freeMemoryMiB() -> Int64 {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let bytes = (UInt64(vm.free_count) + UInt64(vm.inactive_count)) * UInt64(vm_page_size)
        return Int64(bytes / (1024 * 1024))
    }

    private static func usedMemoryMiB() -> Int64 {
        let total = totalMemoryBytes()
        guard total > 0 else { return 0 }
        let totalMiB = Int64(total / (1024 * 1024))
        let freeMiB = freeMemoryMiB()
        guard freeMiB >= 0, freeMiB <= totalMiB else { return 0 }
        return totalMiB - freeMiB
    }

    // MARK: - Uptime

    private static func uptimeSeconds() -> Int64 {
        var boottime = timeval(tv_sec: 0, tv_usec: 0)
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boottime, &size, nil, 0)
        guard boottime.tv_sec > 0 else { return 0 }
        let now = Date().timeIntervalSince1970
        let uptime = now - Double(boottime.tv_sec)
        return uptime > 0 ? Int64(uptime) : 0
    }
}
