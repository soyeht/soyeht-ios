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
/// an app infer other apps' activity with clock precision. Memory is whole
/// MiB, uptime is whole seconds — combined with the bridge's per-pane rate
/// limit, there is no high-resolution timeline to reconstruct.
///
/// `cpuLoadPerCorePercent` may legitimately EXCEED 100: it is the 1-minute
/// load average divided by logical cores, ×100 — a per-core saturation
/// ratio (k8s-style "CPU 355%"), not a utilization gauge. Oversubscription
/// is real information and a monitor must show it; clamping it would turn
/// "severe contention" into "at the ceiling, normal" (decision reversed
/// after celia's review of the first clamp attempt — the field now names
/// what the mechanism actually measures).
struct SystemMetricsSnapshot: Codable, Hashable {
    /// 1-minute load average ÷ logical cores × 100. 0 = idle, 100 = exactly
    /// saturated, values above 100 = oversubscribed per core (queue depth
    /// exceeds what the cores can drain). Unbounded upward by nature.
    let cpuLoadPerCorePercent: Int
    /// Used memory in whole MiB (total − free − inactive).
    let memoryUsedMiB: Int64
    /// Available memory in whole MiB (free + inactive).
    let memoryFreeMiB: Int64
    /// Seconds since boot, whole seconds.
    let uptimeSeconds: Int64
}

/// Collects the system aggregate for `metrics.read`. New code — the repo
/// had no metrics collector before this phase.
///
/// `snapshot()` THROWS on collection failure instead of publishing
/// zero-filled numbers: a snapshot reading "0% CPU, 0 MiB used, 0s uptime"
/// would be the wire lying with real-looking data (the phase's standing
/// rule). The bridge maps a thrown collection to `.internalError`.
enum SystemMetricsCollector {

    enum CollectionError: Error { case unavailable }

    static func snapshot() throws -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpuLoadPerCorePercent: try perCoreLoadPercent(),
            memoryUsedMiB: try usedMemoryMiB(),
            memoryFreeMiB: try freeMemoryMiB(),
            uptimeSeconds: try uptimeSeconds()
        )
    }

    // MARK: - CPU

    private static func perCoreLoadPercent() throws -> Int {
        var load = [Double](repeating: 0, count: 3)
        // getloadavg returns the number of samples retrieved (or -1 on
        // failure) — NOT zero on success. An earlier `== 0` guard made
        // this whole function silently return a 0% load forever; the
        // throwing rewrite exposed it (zeros are how real bugs hide).
        let samples = getloadavg(&load, 3)
        guard samples > 0, load[0] >= 0 else {
            throw CollectionError.unavailable
        }
        return try Self.perCoreLoadPercent(oneMinuteLoad: load[0], logicalCores: logicalCoreCount())
    }

    /// Pure load math, extracted so the normalization is provable with
    /// synthetic fixtures instead of whatever the host machine happens to
    /// be doing. NO clamp: load average is a run-queue ratio, not
    /// utilization — measured on this machine during phase 2b, 70.92 over
    /// 20 cores = 355% on the 1-minute average. Oversubscription above
    /// 100 is real signal a monitor must surface (k8s-style per-core
    /// percentage). Degenerate inputs (negative load, zero cores) fail
    /// closed to 0.
    static func perCoreLoadPercent(oneMinuteLoad: Double, logicalCores: Int32) -> Int {
        guard logicalCores > 0, oneMinuteLoad >= 0 else { return 0 }
        return Int(((oneMinuteLoad / Double(logicalCores)) * 100.0).rounded())
    }

    private static func logicalCoreCount() throws -> Int32 {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &count, &size, nil, 0)
        guard count > 0 else { throw CollectionError.unavailable }
        return count
    }

    // MARK: - Memory

    private static func totalMemoryBytes() throws -> UInt64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        guard total > 0 else { throw CollectionError.unavailable }
        return total
    }

    /// free + inactive pages, in whole MiB. Inactive memory is reclaimable
    /// on demand — reporting it as "used" would be dishonest to the app.
    private static func freeMemoryMiB() throws -> Int64 {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw CollectionError.unavailable }
        let bytes = (UInt64(vm.free_count) + UInt64(vm.inactive_count)) * UInt64(vm_page_size)
        return Int64(bytes / (1024 * 1024))
    }

    private static func usedMemoryMiB() throws -> Int64 {
        let totalMiB = Int64(try totalMemoryBytes() / (1024 * 1024))
        let freeMiB = try freeMemoryMiB()
        guard freeMiB >= 0, freeMiB <= totalMiB else { throw CollectionError.unavailable }
        return totalMiB - freeMiB
    }

    // MARK: - Uptime

    private static func uptimeSeconds() throws -> Int64 {
        var boottime = timeval(tv_sec: 0, tv_usec: 0)
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boottime, &size, nil, 0)
        guard boottime.tv_sec > 0 else { throw CollectionError.unavailable }
        let now = Date().timeIntervalSince1970
        let uptime = now - Double(boottime.tv_sec)
        guard uptime > 0 else { throw CollectionError.unavailable }
        return Int64(uptime)
    }
}
