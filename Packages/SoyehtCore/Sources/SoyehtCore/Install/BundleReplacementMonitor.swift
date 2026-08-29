import Foundation

/// On-disk identity of an executable file.
///
/// Two captures compare unequal whenever the file was replaced or removed:
/// every install-style replacement (`mv`, `ditto`, `cp` over the path)
/// allocates a new inode or rewrites size/mtime, and a deletion flips
/// `exists`. Content hashing is deliberately avoided — the main executable
/// is tens of megabytes and this identity is polled for the lifetime of the
/// process.
///
/// Why this matters: replacing an app bundle on disk while an instance is
/// still running invalidates that instance's code identity. macOS TCC then
/// silently degrades the stale tree's folder grants (Documents, Desktop,
/// Downloads return EPERM with no prompt and no log entry) until the app is
/// relaunched — the 2026-08-28 incident. The monitor below exists so the app
/// notices the swap instead of its users.
public struct ExecutableIdentity: Equatable, Sendable {
    public let exists: Bool
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    public static func capture(atPath path: String) -> ExecutableIdentity {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return ExecutableIdentity(
                exists: false, device: 0, inode: 0, size: 0,
                modifiedSeconds: 0, modifiedNanoseconds: 0
            )
        }
        return ExecutableIdentity(
            exists: true,
            device: status.st_dev,
            inode: status.st_ino,
            size: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }
}

/// Watches the running executable's on-disk identity and reports **once**
/// when it no longer matches the identity captured at initialization.
///
/// The report fires at most one time for the lifetime of the monitor: the
/// interesting transition is "the bundle under this process changed", not
/// every subsequent mutation, and the only remedy — relaunching — replaces
/// the process anyway.
public final class BundleReplacementMonitor: @unchecked Sendable {

    private let executablePath: String
    private let baseline: ExecutableIdentity
    private let onReplaced: (_ baseline: ExecutableIdentity, _ current: ExecutableIdentity) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var hasFired = false

    /// `onReplaced` is invoked on an arbitrary queue; hop to the main actor
    /// before touching UI.
    public init(
        executablePath: String,
        queue: DispatchQueue = DispatchQueue(
            label: "soyeht.bundle-replacement-monitor", qos: .utility
        ),
        onReplaced: @escaping (_ baseline: ExecutableIdentity, _ current: ExecutableIdentity) -> Void
    ) {
        self.executablePath = executablePath
        self.baseline = ExecutableIdentity.capture(atPath: executablePath)
        self.queue = queue
        self.onReplaced = onReplaced
    }

    /// Begin polling. A modest interval is enough: the degraded window the
    /// monitor exists to shorten previously lasted for hours.
    public func start(interval: TimeInterval = 30) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil, !hasFired else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            self?.checkNow()
        }
        source.resume()
        timer = source
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// Compare the current on-disk identity against the baseline. Returns
    /// whether the executable differs from launch time; invokes `onReplaced`
    /// only on the first detection.
    @discardableResult
    public func checkNow() -> Bool {
        let current = ExecutableIdentity.capture(atPath: executablePath)
        guard current != baseline else { return false }

        lock.lock()
        let shouldReport = !hasFired
        hasFired = true
        timer?.cancel()
        timer = nil
        lock.unlock()

        if shouldReport {
            onReplaced(baseline, current)
        }
        return true
    }
}
