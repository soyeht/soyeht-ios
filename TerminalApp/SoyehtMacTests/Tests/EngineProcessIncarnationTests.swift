import Darwin
import XCTest
@testable import SoyehtMacDomain

final class EngineProcessIncarnationTests: XCTestCase {
    func testKernelIdentityIsStableUntilTheOwnedProcessExits() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let pid = UInt32(child.processIdentifier)
        let before = try XCTUnwrap(EngineProcessIncarnation.read(pid: pid))
        XCTAssertEqual(before.pid, pid)
        XCTAssertEqual(EngineProcessIncarnation.read(pid: pid), before)
        XCTAssertNil(EngineProcessIncarnation.read(pid: pid, uid: getuid() + 1))
        child.terminate()
        child.waitUntilExit()
        XCTAssertNotEqual(EngineProcessIncarnation.read(pid: pid), before)
    }

    func testInvalidPIDCannotBecomeAProcessGroupQuery() {
        XCTAssertNil(EngineProcessIncarnation.read(pid: 0))
        XCTAssertNil(EngineProcessIncarnation.read(pid: UInt32.max))
    }
}
