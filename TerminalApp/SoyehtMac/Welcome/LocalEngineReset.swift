import Foundation
import SoyehtCore

/// Stopping the local engine and wiping its on-disk state are needed by three
/// callers: "Reinstall" in the Welcome flow, "Forget this home" in Settings,
/// and the DEBUG reset that puts a Dev Mac back to zero for QA. They used to
/// live inside `WelcomeRootView.swift` as file-private enums; the bodies below
/// are unchanged, only the visibility widened.
enum ExistingSoyehtStopper {
    static func stopKnownServices() async {
        let commands = serviceStopCommands()
        for command in commands {
            await runBestEffort(executable: command.executable, arguments: command.arguments)
        }
    }

    private static func serviceStopCommands() -> [(executable: String, arguments: [String])] {
        // Stop only THIS build's engine. A dev build must never bootout the
        // shipping engine (com.soyeht.engine) and vice versa — otherwise
        // launching one would knock the other offline.
        let engineLabel = SoyehtInstallProfile.current.engineLaunchdLabel
        var commands: [(String, [String])] = [
            ("/bin/launchctl", ["bootout", "gui/\(getuid())/\(engineLabel)"]),
        ]

        for brew in TheyOSEnvironment.brewBinaryCandidates where FileManager.default.isExecutableFile(atPath: brew) {
            commands.append((brew, ["services", "stop", "theyos"]))
        }

        for soyeht in ["/opt/homebrew/bin/soyeht", "/usr/local/bin/soyeht"]
            where FileManager.default.isExecutableFile(atPath: soyeht) {
            commands.append((soyeht, ["stop"]))
        }

        return commands
    }

    private static func runBestEffort(executable: String, arguments: [String]) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                runBestEffortBlocking(executable: executable, arguments: arguments)
                continuation.resume()
            }
        }
    }

    private static func runBestEffortBlocking(executable: String, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return
        }

        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
        }
    }
}

enum ExistingSoyehtStateResetter {
    static func resetLocalEngineState() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                resetLocalEngineStateBlocking()
                continuation.resume()
            }
        }
    }

    private static func resetLocalEngineStateBlocking() {
        let fm = FileManager.default
        // MUST be the current build's support dir. A dev build resetting its
        // engine state must never delete the shipping app's databases /
        // identity / household — TheyOSEnvironment.supportDirectory resolves to
        // "Soyeht" or "SoyehtDev" per SoyehtInstallProfile.
        let supportDir = TheyOSEnvironment.supportDirectory

        let files = [
            "theyos.db", "theyos.db-shm", "theyos.db-wal",
            "theyos.sessions.db", "theyos.sessions.db-shm", "theyos.sessions.db-wal",
            "theyos-sessions.db", "theyos-sessions.db-shm", "theyos-sessions.db-wal",
            "theyos.mobile-sessions.db", "theyos.mobile-sessions.db-shm", "theyos.mobile-sessions.db-wal",
            "jobs-rs.db", "jobs-rs.db-shm", "jobs-rs.db-wal",
            "ratelimit.db", "ratelimit.db-shm", "ratelimit.db-wal",
            "identity.bootstrap_state",
            "household.tearing-down",
        ]

        for file in files {
            try? fm.removeItem(at: supportDir.appendingPathComponent(file, isDirectory: false))
        }

        // The engine keeps the household under `household-state/`
        // (`household-state/household/…`, `household-state/identity.bootstrap_state`),
        // not at the support-directory root. Until 2026-09-01 this removed
        // `<support>/household`, which does not exist, so "reinstall" left the
        // household on disk and the fresh engine booted straight back to
        // `ready` with the old home.
        try? fm.removeItem(at: supportDir.appendingPathComponent("household-state", isDirectory: true))
        try? fm.removeItem(at: supportDir.appendingPathComponent("household", isDirectory: true))
    }
}
