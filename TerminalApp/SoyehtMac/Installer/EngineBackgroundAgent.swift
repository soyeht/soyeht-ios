import Foundation
import os

/// Installs and drives the engine's launchd job in the USER domain
/// (`user/<uid>`), where it outlives the graphical session.
///
/// Why not `SMAppService`: it registers an agent into `gui/<uid>`, the Aqua
/// session, which launchd tears down at logout. On 2026-09-04 the
/// WindowServer exited on the owner's Mac, loginwindow closed the session,
/// and the engine died with it — taking every brokered PTY, after the whole
/// promise of the broker was that sessions outlive the app. A job marked
/// `LimitLoadToSessionType = Background` is loaded into the user domain
/// instead; `bootstrap gui/<uid>` REFUSES such a plist (EIO), which is the
/// guarantee, not a limitation.
///
/// The user domain has no on-disk directory of its own — `~/Library/
/// LaunchAgents` is the Aqua one — so the load goes through the legacy
/// `launchctl load -S Background`, the one interface that names a session
/// type. `bootstrap user/<uid>` is the modern spelling and wants root; this
/// needs none, which keeps the zero-sudo install (FR-012) intact.
enum EngineBackgroundAgent {
    private static let log = Logger(subsystem: "com.soyeht.mac", category: "EngineBackgroundAgent")

    /// Where launchd reads this profile's job from. The file has to exist on
    /// disk at every login, not only when the app runs: that is what starts
    /// the engine again after a reboot with nobody logged in yet.
    static func installedPlistURL(
        label: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    // MARK: - Reading the world

    /// Is this profile's job loaded in the user domain right now?
    static func isLoadedInUserDomain(label: String) -> Bool {
        launchctl(["print", "user/\(getuid())/\(label)"]).status == 0
    }

    /// Is it still loaded in the graphical session — the domain being left?
    static func isLoadedInGUIDomain(label: String) -> Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    /// How long to wait for launchd to release a booted-out label before
    /// loading over it. Generous next to the ~20 ms launchd actually takes,
    /// because the alternative — loading too early — costs every live session
    /// and leaves nothing running.
    static let labelReleaseBudget: TimeInterval = 5

    /// Blocks until `label` is absent from BOTH domains, or the budget runs
    /// out. Returns whether the name came free.
    ///
    /// Pure enough to test through its two seams: the probe and the sleep.
    @discardableResult
    static func awaitLabelReleased(
        label: String,
        budget: TimeInterval = EngineBackgroundAgent.labelReleaseBudget,
        stillLoaded: ((String) -> Bool)? = nil,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        let probe = stillLoaded ?? { name in
            isLoadedInUserDomain(label: name) || isLoadedInGUIDomain(label: name)
        }
        let step: TimeInterval = 0.05
        var waited: TimeInterval = 0
        while probe(label) {
            guard waited < budget else { return false }
            sleep(step)
            waited += step
        }
        return true
    }

    /// Does the installed copy match what this build ships? A wrapper change
    /// (a new export, a moved log) reaches launchd only when the file does.
    static func installedPlistIsCurrent(bundled: URL, label: String) -> Bool {
        let installed = installedPlistURL(label: label)
        guard let a = try? Data(contentsOf: bundled),
              let b = try? Data(contentsOf: installed) else { return false }
        return a == b
    }

    // MARK: - Changing the world

    enum InstallOutcome: Equatable {
        case installed
        case failed(String)
    }

    /// Copies the bundled plist into `~/Library/LaunchAgents` and loads it
    /// into the user domain.
    ///
    /// Idempotent by construction: an already-loaded job is unloaded first,
    /// because `load` on a live label is a no-op that would silently keep the
    /// previous command line. Callers decide WHEN this is allowed to happen —
    /// it stops a running engine, and that costs whatever is attached to it.
    @discardableResult
    static func install(bundledPlist: URL, label: String) -> InstallOutcome {
        let destination = installedPlistURL(label: label)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Data(contentsOf: bundledPlist)
            try data.write(to: destination, options: .atomic)
        } catch {
            log.error("could not install \(label, privacy: .public) plist: \(error.localizedDescription, privacy: .public)")
            return .failed("plist: \(error.localizedDescription)")
        }

        // Both domains, in this order: the GUI job is the one being replaced,
        // and leaving it loaded would keep the label taken.
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        _ = launchctl(["bootout", "user/\(getuid())/\(label)"])

        // `bootout` RETURNS BEFORE launchd has finished releasing the label,
        // and loading into a name launchd still holds fails with EEXIST.
        //
        // MEASURED on the owner's Mac 2026-09-05, 18 ms apart:
        //
        //     14:24:05.134  bootout gui/501/com.soyeht.engine [37543]
        //     14:24:05.152  launchd: Caller tried to import service with same
        //                   label as an existing service ... failed (17: File exists)
        //
        // The engine was gone and nothing replaced it — eleven agent sessions
        // died and the machine sat with no engine for thirty-six seconds, until
        // an unrelated relaunch happened to re-bootstrap it. The old code could
        // not even see the failure coming: `launchctl load` reports success
        // whether or not launchd accepted the job, so the only witness was the
        // `isLoadedInUserDomain` check AFTER the kill.
        //
        // So wait for the name to actually come free. A poll, because launchd
        // offers nothing to wait on.
        if !awaitLabelReleased(label: label) {
            log.error("\(label, privacy: .public) was still loaded \(Self.labelReleaseBudget, privacy: .public)s after bootout; loading anyway")
        }

        let load = launchctl(["load", "-S", "Background", destination.path])
        guard load.status == 0 else {
            log.error("launchctl load -S Background failed for \(label, privacy: .public): \(load.output, privacy: .public)")
            return .failed("load: \(load.output)")
        }
        // One retry, because the whole cost of this call has ALREADY been paid:
        // the engine is dead either way, and giving up here is what left the
        // Mac with no engine at all. A second attempt after the name is
        // provably free costs a second and can only help.
        if !isLoadedInUserDomain(label: label) {
            log.error("\(label, privacy: .public) did not appear in the user domain; the engine is already down, so retrying the load")
            _ = awaitLabelReleased(label: label)
            let retry = launchctl(["load", "-S", "Background", destination.path])
            if retry.status != 0 {
                log.error("retry of launchctl load -S Background failed for \(label, privacy: .public): \(retry.output, privacy: .public)")
            }
        }
        guard isLoadedInUserDomain(label: label) else {
            log.error("\(label, privacy: .public) did not appear in the user domain after loading")
            return .failed("not in user domain after load")
        }
        log.notice("engine job loaded in the user domain: \(label, privacy: .public)")
        return .installed
    }

    /// Restarts the job in place — used after a newer engine binary is staged,
    /// and only where the caller has established that the cost is acceptable.
    static func restart(label: String) {
        _ = launchctl(["kickstart", "-k", "user/\(getuid())/\(label)"])
    }

    /// Starts a stopped job without disturbing a running one.
    static func startIfStopped(label: String) {
        _ = launchctl(["kickstart", "user/\(getuid())/\(label)"])
    }

    /// Removes the job and the installed plist (uninstall, "start from
    /// scratch"). Deliberately silent about failures: every caller is already
    /// tearing things down and none can act on a partial result.
    static func remove(label: String) {
        _ = launchctl(["bootout", "user/\(getuid())/\(label)"])
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: installedPlistURL(label: label))
    }

    // MARK: - launchctl

    private struct Result {
        let status: Int32
        let output: String
    }

    private static func launchctl(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
