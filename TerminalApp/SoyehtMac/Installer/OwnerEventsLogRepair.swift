import Foundation

/// Tightens a legacy world-readable owner-events log before the engine reads it.
///
/// Engines before theyos `9ded9731` (2026-08-05) wrote
/// `household-state/household/owner_events/log.cbor` as `0644`. Every engine
/// since refuses any mode with group/other bits, and the refusal lands in
/// Phase 3 of the bootstrap: the household listener never binds, the iPhone
/// never reaches the Mac again, and `/health` keeps answering `ok`. The
/// engine repairs the file itself from theyos `b05d2119` on — but the engine
/// installed on a set-up Mac is only refreshed when a stale one is bounced,
/// so this app-side repair is the channel that reaches a Mac still running
/// the older engine. It runs before anything that could start or restart the
/// engine, so the next boot sees the mode the engine demands.
///
/// Same invariants as the engine's own repair: only a regular file, owned by
/// this user, with exactly one link, opened without following symlinks, is
/// touched. Anything else is left exactly as found for the engine to reject.
/// No AppKit: this file is symlinked into the isolated domain test package.
enum OwnerEventsLogRepair {

    enum Outcome: Equatable {
        /// No log on disk — fresh install, or the household never paired.
        case absent
        /// Already `0600` (or tighter); nothing to do.
        case alreadyPrivate
        /// Was group/other-readable; now `0600`.
        case repaired(previousMode: mode_t)
        /// Fails an invariant the repair must not paper over.
        case leftAlone(reason: String)
        /// The open, stat, or chmod itself failed.
        case failed(errno: Int32)
    }

    /// Relative to the profile's support directory
    /// (`~/Library/Application Support/Soyeht` or `…/SoyehtDev`).
    static let relativeLogPath = "household-state/household/owner_events/log.cbor"

    static func logURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(relativeLogPath)
    }

    static func repair(logURL: URL) -> Outcome {
        let fd = open(logURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            return code == ENOENT ? .absent : .failed(errno: code)
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failed(errno: errno) }

        let mode = info.st_mode & 0o7777
        if mode & 0o077 == 0 {
            return .alreadyPrivate
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .leftAlone(reason: "not a regular file")
        }
        guard info.st_uid == getuid() else {
            return .leftAlone(reason: "owned by uid \(info.st_uid), not \(getuid())")
        }
        guard info.st_nlink == 1 else {
            return .leftAlone(reason: "\(info.st_nlink) links share these bytes")
        }
        guard fchmod(fd, 0o600) == 0 else { return .failed(errno: errno) }
        return .repaired(previousMode: mode)
    }
}
