import Darwin
import Foundation

/// Asks the installed engine whether IT is trusted for macOS Accessibility,
/// and lets it prompt for that grant.
///
/// macOS attributes an Accessibility check to the process responsible for
/// it, identified by its executable. Pane shells hang off the PTY
/// supervisor, which runs from the engine file (`theyos-engine ptyd`), so the
/// grant an agent in a pane needs is the engine's, not this app's. Checking
/// `AXIsProcessTrusted()` here reported "granted" for the app while every
/// pane was refused (2026-09-08). The engine is therefore spawned with launch
/// responsibility disclaimed: the child becomes its own responsible process,
/// and both the answer and the system prompt carry the engine's identity.
enum EngineAccessibilityProbe {
    struct Reply: Decodable, Equatable {
        let trusted: Bool
        let prompted: Bool
        let supported: Bool
    }

    /// `nil` when the engine is not installed, could not be run, or did not
    /// answer in time; callers fall back to asking for the app itself.
    static func check(engine: URL, prompt: Bool) -> Reply? {
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { return nil }
        var arguments = ["accessibility"]
        if prompt { arguments.append("--prompt") }
        // A prompt blocks until the person answers the system dialog.
        let timeout: TimeInterval = prompt ? 180 : 10
        guard let output = runDisclaimed(executable: engine, arguments: arguments, timeout: timeout) else {
            return nil
        }
        return parse(output)
    }

    static func parse(_ output: Data) -> Reply? {
        try? JSONDecoder().decode(Reply.self, from: output)
    }

    /// Spawns `executable` as its own responsible process and returns its
    /// stdout, or `nil` on spawn failure, non-zero exit, or timeout.
    static func runDisclaimed(executable: URL, arguments: [String], timeout: TimeInterval) -> Data? {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return nil }
        let readEnd = pipe[0]
        let writeEnd = pipe[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The point of this launcher: macOS holds the child, not this app,
        // responsible for what the child asks the system. Without the
        // disclaim the answer would be about this app, so refuse to run.
        guard responsibility_spawnattrs_setdisclaim(&attributes, 1) == 0 else {
            close(readEnd)
            close(writeEnd)
            return nil
        }

        let argv = [executable.path] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, cArgs, environ)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return nil
        }

        let collected = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
            output = handle.readDataToEndOfFile()
            collected.signal()
        }
        if collected.wait(timeout: .now() + timeout) == .timedOut {
            kill(pid, SIGKILL)
            _ = collected.wait(timeout: .now() + 2)
            var ignored: Int32 = 0
            waitpid(pid, &ignored, 0)
            return nil
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // WIFEXITED && WEXITSTATUS == 0
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else { return nil }
        return output
    }
}

/// Public in libSystem since macOS 10.14 (it is how terminals give their
/// shells a TCC identity of their own); declared here because the SDK
/// headers do not expose it to Swift.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(
    _ attributes: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32
) -> Int32
