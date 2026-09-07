import Darwin
import Foundation

/// Kernel process identity for the one-time legacy migration. This is not an
/// engine-reported boot ID or executable image identity. Recording PID alone
/// would allow a resumed removal to target a different process after PID reuse.
struct EngineProcessIncarnation: Codable, Equatable, Sendable {
    let pid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(pid: UInt32, uid: UInt32 = getuid()) -> Self? {
        guard let processID = Int32(exactly: pid), processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == pid, info.pbi_uid == uid,
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
        return .init(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}
