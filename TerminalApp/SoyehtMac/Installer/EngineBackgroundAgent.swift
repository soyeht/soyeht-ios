import Foundation
import os

/// Installs the engine job in the user's Background session domain.
/// Replacing this job terminates an in-process terminal backend. The caller
/// must establish that replacement is allowed; this helper does not inventory
/// sessions and must never be used to refresh a live PTY supervisor.
enum EngineBackgroundAgent {
    private static let log = Logger(subsystem: "com.soyeht.mac", category: "EngineBackgroundAgent")

    /// Persistent plist location for this profile. Loading and observing the
    /// job are separate operations; this path alone proves no running service.
    static func installedPlistURL(
        label: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    // MARK: - Reading the world

    /// Positive observation only. A false value is not proof of absence;
    /// replacement uses JobPresence so probe errors cannot release a label.
    static func isLoadedInUserDomain(label: String) -> Bool {
        presence(domain: "user", label: label) == .present
    }

    /// Is it still loaded in the graphical session — the domain being left?
    static func isLoadedInGUIDomain(label: String) -> Bool {
        presence(domain: "gui", label: label) == .present
    }

    enum JobPresence: Equatable { case present, absent, unknown }

    static func classifyPresence(_ result: Result, domain: String, label: String, uid: UInt32) -> JobPresence {
        if result.status == 0 { return .present }
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if result.status == 113,
           lines.contains("Could not find service \"\(label)\" in domain for uid: \(uid)") { return .absent }
        if result.status == 112, domain == "gui",
           lines.contains("Could not find domain for user gui: \(uid)") { return .absent }
        return .unknown
    }

    private static func presence(domain: String, label: String) -> JobPresence {
        classifyPresence(launchctl(["print", "\(domain)/\(getuid())/\(label)"]),
                         domain: domain, label: label, uid: getuid())
    }

    /// Maximum poll budget before refusing to load over a retained label.
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
            presence(domain: "user", label: name) != .absent
                || presence(domain: "gui", label: name) != .absent
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

    /// Stages the plist, then explicitly replaces the engine job. This is a
    /// destructive operation, even when the staged plist has identical bytes.
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

        return replaceLoadedJob(label: label, destination: destination, operations: .live)
    }

    /// Complete service boundary for deterministic tests. Production uses
    /// launchctl; tests record commands without touching an installed job.
    struct Operations {
        var run: ([String]) -> Result
        var waitForRelease: (String) -> Bool
        var isLoaded: (String) -> Bool

        static var live: Operations {
            Operations(
                run: { launchctl($0) },
                waitForRelease: { awaitLabelReleased(label: $0) },
                isLoaded: { isLoadedInUserDomain(label: $0) }
            )
        }
    }

    static func replaceLoadedJob(
        label: String, destination: URL, operations: Operations
    ) -> InstallOutcome {
        _ = operations.run(["bootout", "gui/\(getuid())/\(label)"])
        _ = operations.run(["bootout", "user/\(getuid())/\(label)"])

        // bootout completion is not label release. A timeout is an unresolved
        // replacement, never permission to load into a still-owned name.
        guard operations.waitForRelease(label) else {
            log.error("engine label release timed out; refusing load")
            return .failed("label release timed out")
        }

        let arguments = ["load", "-S", "Background", destination.path]
        let load = operations.run(arguments)
        guard load.status == 0 else {
            return .failed("load: \(load.output)")
        }
        if operations.isLoaded(label) { return .installed }

        // A successful command is not proof of registration. Retry once only
        // after proving the name free again, then require observed membership.
        guard operations.waitForRelease(label) else {
            return .failed("label release timed out before load retry")
        }
        let retry = operations.run(arguments)
        guard retry.status == 0 else { return .failed("load retry: \(retry.output)") }
        guard operations.isLoaded(label) else {
            return .failed("not in user domain after load")
        }
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

    struct Result {
        let status: Int32
        let output: String
    }

    private static func launchctl(_ arguments: [String]) -> Result {
        do {
            let result = try EngineCommandRunner.runBlocking(
                executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments
            )
            if result.timedOut { return Result(status: -1, output: "launchctl timed out; result unconfirmed") }
            if result.outputTruncated { return Result(status: -1, output: "launchctl output exceeded limit") }
            return Result(status: result.status, output: String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
    }
}
