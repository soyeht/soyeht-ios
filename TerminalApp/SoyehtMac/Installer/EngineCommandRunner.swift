import Foundation
import Darwin

/// Bounded subprocess boundary for installer probes and launchctl commands.
/// Call off the main thread. Capturing into private files avoids pipe backpressure
/// and waiting for EOF from a descendant that inherited an output descriptor.
enum EngineCommandRunner {
    struct Result {
        let status: Int32
        let output: Data
        let timedOut: Bool
        let outputTruncated: Bool
        var succeeded: Bool { status == 0 && !timedOut && !outputTruncated }
    }

    static func runBlocking(
        executable: URL, arguments: [String], timeout: TimeInterval = 5,
        outputLimit: Int = 65_536
    ) throws -> Result {
        precondition(timeout > 0 && timeout <= 60 && outputLimit > 0 && outputLimit < Int.max)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("soyeht-command-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("output")
        guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let writer = try FileHandle(forWritingTo: outputURL)
        defer { try? writer.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = writer
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                // This is the command child we created, never the engine or
                // supervisor service named in a launchctl argument.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: outputLimit + 1) ?? Data()
        return Result(
            status: process.isRunning ? -1 : process.terminationStatus,
            output: Data(bytes.prefix(outputLimit)),
            timedOut: timedOut,
            outputTruncated: bytes.count > outputLimit
        )
    }
}
