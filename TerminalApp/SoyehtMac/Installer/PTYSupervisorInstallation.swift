import Foundation
import SoyehtCore

/// One profile's independent PTY owner. This type describes and verifies its
/// installation; it cannot stop, replace or signal a running supervisor.
///
/// The daemon runs from the engine's own file (`theyos-engine ptyd`), not
/// from the `soyeht-ptyd` helper. macOS grants Accessibility per executable
/// path, and the supervisor is the parent of every pane shell, so its path is
/// what a person has to authorise before an agent in a pane can drive other
/// apps. Measured 2026-09-08 on the owner's Mac: `Soyeht` and `theyos-engine`
/// were already authorised, `soyeht-ptyd` appeared as a third, unauthorised
/// program, and every agent lost Accessibility with the 0.1.50 update. One
/// file for engine and supervisor means one grant, already given, that
/// survives engine updates because it follows the path and the signing team.
///
/// `soyeht-ptyd` stays in the package for read-only calls (`--contract`,
/// `--status`) that must never run the engine binary on disk before it is
/// known to carry the subcommand, and for daemons an earlier release loaded.
struct PTYSupervisorInstallation {
    let profile: SoyehtInstallProfile
    let home: URL

    var label: String { profile.ptySupervisorLaunchdLabel }
    var support: URL { home.appendingPathComponent("Library/Application Support/\(profile.supportDirectoryName)", isDirectory: true) }
    var root: URL { support.appendingPathComponent("ptyd", isDirectory: true) }
    var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    var socket: URL { root.appendingPathComponent("control.sock") }
    /// The helper used for `--contract` and `--status`. Read-only callers.
    var executable: URL { support.appendingPathComponent("engine/soyeht-ptyd") }
    /// The program the LaunchAgent runs: the engine file, in supervisor mode.
    var program: URL { support.appendingPathComponent("engine/theyos-engine") }
    var log: URL { home.appendingPathComponent("Library/Logs/\(profile.engineLogDirectoryName)/ptyd.log") }
    var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    var arguments: [String] { [program.path, "ptyd", "--socket", socket.path, "--state-dir", state.path] }
    /// What a job loaded by a release before the `ptyd` subcommand looks like.
    /// It keeps owning its sessions untouched; only the definition on disk is
    /// refreshed so the next login starts the daemon from the engine file.
    var legacyArguments: [String] { [executable.path, "--socket", socket.path, "--state-dir", state.path] }

    enum LayoutError: Error { case invalidPath, socketPathTooLong }

    /// Absolute paths are literal plist values, never shell expansions. Reject
    /// paths that cannot be checked faithfully against launchctl's line format.
    func plistData() throws -> Data {
        let paths = [home, root, state, socket, executable, program, log, plist].map(\.path)
        guard home.isFileURL, paths.allSatisfy({
            $0.hasPrefix("/") && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw LayoutError.invalidPath }
        // Darwin sockaddr_un.sun_path includes its terminating NUL in 104 bytes.
        guard socket.path.utf8.count < 104 else { throw LayoutError.socketPathTooLong }
        return try PropertyListSerialization.data(fromPropertyList: [
            "Label": label,
            "ProgramArguments": arguments,
            "WorkingDirectory": state.path,
            "LimitLoadToSessionType": "Background",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "Umask": 0o077,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ], format: .xml, options: 0)
    }

    /// Verify the top-level program/argv and match the launchd PID to the
    /// kernel-reported UDS peer PID. A matching label or file path alone is
    /// insufficient; nested diagnostic fields cannot stand in for job fields.
    /// A job still running the legacy helper qualifies: the wire protocol,
    /// not the program path, decides compatibility, and restarting it to
    /// change the path would destroy the sessions it exists to preserve.
    func matchesLoadedJob(_ output: String, uid: UInt32, status: PTYSupervisorStatus) -> Bool {
        guard let job = LaunchdJobSnapshot(output: output, domain: "user", label: label, uid: uid),
              let brokerPID = status.brokerPID, brokerPID > 0, job.pid == brokerPID else { return false }
        return (job.program == program.path && job.arguments == arguments)
            || (job.program == executable.path && job.arguments == legacyArguments)
    }

    /// True when the loaded job is the legacy helper form, so the plist on
    /// disk still names it and needs the engine-file definition for next login.
    func loadedJobIsLegacy(_ output: String, uid: UInt32) -> Bool {
        guard let job = LaunchdJobSnapshot(output: output, domain: "user", label: label, uid: uid) else { return false }
        return job.program == executable.path && job.arguments == legacyArguments
    }
}
