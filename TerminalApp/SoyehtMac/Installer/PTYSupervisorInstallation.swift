import Foundation
import SoyehtCore

/// One profile's independent PTY owner. This type describes and verifies its
/// installation; it cannot stop, replace or signal a running supervisor.
struct PTYSupervisorInstallation {
    let profile: SoyehtInstallProfile
    let home: URL

    var label: String { profile.ptySupervisorLaunchdLabel }
    var support: URL { home.appendingPathComponent("Library/Application Support/\(profile.supportDirectoryName)", isDirectory: true) }
    var root: URL { support.appendingPathComponent("ptyd", isDirectory: true) }
    var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    var socket: URL { root.appendingPathComponent("control.sock") }
    var executable: URL { support.appendingPathComponent("engine/soyeht-ptyd") }
    var log: URL { home.appendingPathComponent("Library/Logs/\(profile.engineLogDirectoryName)/ptyd.log") }
    var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    var arguments: [String] { [executable.path, "--socket", socket.path, "--state-dir", state.path] }

    enum LayoutError: Error { case invalidPath, socketPathTooLong }

    /// Absolute paths are literal plist values, never shell expansions. Reject
    /// paths that cannot be checked faithfully against launchctl's line format.
    func plistData() throws -> Data {
        let paths = [home, root, state, socket, executable, log, plist].map(\.path)
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
    func matchesLoadedJob(_ output: String, uid: UInt32, status: PTYSupervisorStatus) -> Bool {
        guard let job = LaunchdJobSnapshot(output: output, domain: "user", label: label, uid: uid),
              let brokerPID = status.brokerPID, brokerPID > 0 else { return false }
        return job.program == executable.path && job.arguments == arguments && job.pid == brokerPID
    }
}
