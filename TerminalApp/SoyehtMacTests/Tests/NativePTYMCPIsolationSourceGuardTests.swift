import Darwin
import Foundation
import XCTest
@testable import SoyehtMacDomain

final class NativePTYMCPIsolationSourceGuardTests: XCTestCase {
    func testRegularFileIsNotClassifiedAsTerminalStandardIO() throws {
        let targetPTY = try makePTYPair()
        defer { targetPTY.close() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativepty-stdio-\(UUID().uuidString)")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let file = try FileHandle(forUpdating: fileURL)
        defer { try? file.close() }

        try withSleepingProcess(input: file, output: file) { process in
            XCTAssertFalse(
                NativePTY.hasTerminalStandardIO(
                    process.processIdentifier,
                    ttyDevice: targetPTY.device
                )
            )
        }
    }

    func testDevNullIsNotClassifiedAsTerminalStandardIO() throws {
        let targetPTY = try makePTYPair()
        defer { targetPTY.close() }
        let devNull = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
        defer { try? devNull.close() }

        try withSleepingProcess(input: devNull, output: devNull) { process in
            XCTAssertFalse(
                NativePTY.hasTerminalStandardIO(
                    process.processIdentifier,
                    ttyDevice: targetPTY.device
                )
            )
        }
    }

    func testDifferentPTYIsNotClassifiedAsTerminalStandardIO() throws {
        let targetPTY = try makePTYPair()
        defer { targetPTY.close() }
        let otherPTY = try makePTYPair()
        defer { otherPTY.close() }
        let otherSlave = FileHandle(fileDescriptor: otherPTY.slave, closeOnDealloc: false)

        try withSleepingProcess(input: otherSlave, output: otherSlave) { process in
            XCTAssertFalse(
                NativePTY.hasTerminalStandardIO(
                    process.processIdentifier,
                    ttyDevice: targetPTY.device
                )
            )
        }
    }

    func testPipeIsNotClassifiedAsTerminalStandardIO() throws {
        let targetPTY = try makePTYPair()
        defer { targetPTY.close() }
        let input = Pipe()
        let output = Pipe()

        try withSleepingProcess(input: input, output: output) { process in
            XCTAssertFalse(
                NativePTY.hasTerminalStandardIO(
                    process.processIdentifier,
                    ttyDevice: targetPTY.device
                )
            )
        }
    }

    func testSocketIsNotClassifiedAsTerminalStandardIO() throws {
        let targetPTY = try makePTYPair()
        defer { targetPTY.close() }
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw posixError("socketpair")
        }
        defer {
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
        }
        let socket = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: false)

        try withSleepingProcess(input: socket, output: socket) { process in
            XCTAssertFalse(
                NativePTY.hasTerminalStandardIO(
                    process.processIdentifier,
                    ttyDevice: targetPTY.device
                )
            )
        }
    }

    func testMatchingPTYSlaveIsClassifiedAsTerminalStandardIO() throws {
        let targetPTY = try makePTYPair()
        defer { targetPTY.close() }
        let slave = FileHandle(fileDescriptor: targetPTY.slave, closeOnDealloc: false)

        try withSleepingProcess(input: slave, output: slave) { process in
            XCTAssertTrue(
                NativePTY.hasTerminalStandardIO(
                    process.processIdentifier,
                    ttyDevice: targetPTY.device
                )
            )
        }
    }

    func testVnodeWithUnavailableDescriptorMetadataFailsSafeByIncluding() {
        XCTAssertTrue(
            NativePTY.hasTerminalStandardIO(
                42,
                ttyDevice: 7,
                descriptorTypes: { _ in
                    [
                        STDIN_FILENO: .vnode,
                        STDOUT_FILENO: .other,
                    ]
                },
                descriptorMetadata: { _, _ in nil }
            )
        )
    }

    func testUnavailableDescriptorTypeEnumerationFailsSafeByIncluding() {
        XCTAssertTrue(
            NativePTY.hasTerminalStandardIO(
                42,
                ttyDevice: 7,
                descriptorTypes: { _ in nil },
                descriptorMetadata: { _, _ in
                    XCTFail("vnode metadata must not be queried without descriptor types")
                    return nil
                }
            )
        )
    }

    func testInspectableNonVnodeDescriptorsRemainExcluded() {
        XCTAssertFalse(
            NativePTY.hasTerminalStandardIO(
                42,
                ttyDevice: 7,
                descriptorTypes: { _ in
                    [
                        STDIN_FILENO: .other,
                        STDOUT_FILENO: .other,
                    ]
                },
                descriptorMetadata: { _, _ in
                    XCTFail("non-vnode descriptors must not request vnode metadata")
                    return nil
                }
            )
        )
    }

    func testRecycledPIDIsSkippedBeforeEscalation() {
        let captured = NativePTY.ProcessIdentity(
            pid: 4242,
            startTime: NativePTY.ProcessStartTime(seconds: 17, microseconds: 23)
        )
        var sentSignals: [(pid_t, Int32)] = []

        let signaled = NativePTY.signalProcessesForEscalation(
            [captured],
            signal: SIGTERM,
            startTime: { _ in
                // Same PID and second, different microsecond: a recycled
                // process must not receive the old pane's escalation.
                NativePTY.ProcessStartTime(seconds: 17, microseconds: 24)
            },
            sendSignal: { pid, signal in
                sentSignals.append((pid, signal))
                return 0
            }
        )

        XCTAssertFalse(signaled)
        XCTAssertTrue(sentSignals.isEmpty)
    }

    func testUnavailableStartTimeSkipsEscalation() {
        let captured = NativePTY.ProcessIdentity(
            pid: 4242,
            startTime: NativePTY.ProcessStartTime(seconds: 17, microseconds: 23)
        )
        var sentSignals: [(pid_t, Int32)] = []

        let signaled = NativePTY.signalProcessesForEscalation(
            [captured],
            signal: SIGKILL,
            startTime: { _ in nil },
            sendSignal: { pid, signal in
                sentSignals.append((pid, signal))
                return 0
            }
        )

        XCTAssertFalse(signaled)
        XCTAssertTrue(sentSignals.isEmpty)
    }

    func testMatchingStartTimeAllowsEscalation() {
        let startTime = NativePTY.ProcessStartTime(seconds: 17, microseconds: 23)
        let captured = NativePTY.ProcessIdentity(pid: 4242, startTime: startTime)
        var sentSignals: [(pid_t, Int32)] = []

        let signaled = NativePTY.signalProcessesForEscalation(
            [captured],
            signal: SIGTERM,
            startTime: { _ in startTime },
            sendSignal: { pid, signal in
                sentSignals.append((pid, signal))
                return 0
            }
        )

        XCTAssertTrue(signaled)
        XCTAssertEqual(sentSignals.count, 1)
        XCTAssertEqual(sentSignals.first?.0, 4242)
        XCTAssertEqual(sentSignals.first?.1, SIGTERM)
    }

    func testPTYReaperTargetsTerminalJobsWithoutKillingPipeBackedMCPHelpers() throws {
        let source = try macSource("SoyehtInstance/NativePTY.swift")

        XCTAssertTrue(source.contains("procPIDListFDs"))
        XCTAssertTrue(source.contains("PROC_PIDFDVNODEINFO"))
        XCTAssertTrue(source.contains("hasTerminalStandardIO"))
        XCTAssertTrue(source.contains("descriptorTypes"))
        XCTAssertTrue(source.contains("case .vnode"))
        XCTAssertTrue(source.contains("mode_t(S_IFCHR)"))
        XCTAssertTrue(source.contains("metadata.device == ttyDevice"))
        XCTAssertTrue(source.contains("ProcessStartTime"))
        XCTAssertTrue(source.contains("pbi_start_tvsec"))
        XCTAssertTrue(source.contains("pbi_start_tvusec"))
        XCTAssertTrue(source.contains("signalProcessesForEscalation"))
        XCTAssertTrue(source.contains("signalProcesses(terminalPIDs, signal: SIGHUP)"))
        XCTAssertFalse(
            source.contains("Darwin.kill(-pid, SIGHUP)"),
            "A process-group SIGHUP also kills pipe-backed MCP children."
        )
        XCTAssertFalse(
            source.contains("Darwin.kill(-pgid, sig)"),
            "Escalation must target classified terminal jobs, not every process in the group."
        )
    }

    private struct PTYPair {
        let master: Int32
        let slave: Int32
        let device: UInt32

        func close() {
            Darwin.close(master)
            Darwin.close(slave)
        }
    }

    private func makePTYPair() throws -> PTYPair {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw posixError("openpty")
        }
        var metadata = stat()
        guard fstat(slave, &metadata) == 0 else {
            let error = posixError("fstat")
            Darwin.close(master)
            Darwin.close(slave)
            throw error
        }
        return PTYPair(master: master, slave: slave, device: UInt32(metadata.st_rdev))
    }

    private func withSleepingProcess(
        input: Any,
        output: Any,
        body: (Process) throws -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
        try body(process)
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed with errno \(errno)"]
        )
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
