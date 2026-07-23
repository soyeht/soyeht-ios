import Darwin
import Foundation
import XCTest
@testable import SoyehtMacDomain

final class NativePTYMCPIsolationSourceGuardTests: XCTestCase {
    func testPipeBackedHelperIsNotClassifiedAsATerminalJob() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        XCTAssertFalse(NativePTY.hasTerminalStandardIO(process.processIdentifier))
    }

    func testPTYBackedProcessIsClassifiedAsATerminalJob() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer {
            Darwin.close(master)
            Darwin.close(slave)
        }

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        XCTAssertTrue(NativePTY.hasTerminalStandardIO(process.processIdentifier))
    }

    func testPTYReaperTargetsTerminalJobsWithoutKillingPipeBackedMCPHelpers() throws {
        let source = try macSource("SoyehtInstance/NativePTY.swift")

        XCTAssertTrue(source.contains("procPIDListFDs"))
        XCTAssertTrue(source.contains("hasTerminalStandardIO"))
        XCTAssertTrue(source.contains("descriptor.procFD == STDIN_FILENO"))
        XCTAssertTrue(source.contains("descriptor.procFD == STDOUT_FILENO"))
        XCTAssertTrue(source.contains("descriptor.procFDType == procFDTypeVnode"))
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

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
