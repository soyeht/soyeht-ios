import XCTest
@testable import SoyehtCore

final class BundleReplacementMonitorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bundle-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, to name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url.path
    }

    func testIdentityOfMissingFileDoesNotExist() {
        let identity = ExecutableIdentity.capture(atPath: directory.appendingPathComponent("absent").path)
        XCTAssertFalse(identity.exists)
    }

    func testUntouchedFileKeepsItsIdentity() throws {
        let path = try write("stable", to: "binary")
        XCTAssertEqual(ExecutableIdentity.capture(atPath: path), ExecutableIdentity.capture(atPath: path))

        let monitor = BundleReplacementMonitor(executablePath: path) { _, _ in
            XCTFail("no replacement happened")
        }
        XCTAssertFalse(monitor.checkNow())
    }

    func testMoveOverReplacementIsDetectedAndReportedOnce() throws {
        let path = try write("version one", to: "binary")
        var reports: [(ExecutableIdentity, ExecutableIdentity)] = []
        let monitor = BundleReplacementMonitor(executablePath: path) { baseline, current in
            reports.append((baseline, current))
        }

        // The install pattern: stage elsewhere, then rename over the path.
        let staged = try write("version two", to: "staged")
        XCTAssertEqual(rename(staged, path), 0)

        XCTAssertTrue(monitor.checkNow())
        XCTAssertTrue(monitor.checkNow(), "difference persists after the first report")
        XCTAssertEqual(reports.count, 1, "the replacement is reported exactly once")
        XCTAssertTrue(reports[0].0.exists)
        XCTAssertTrue(reports[0].1.exists)
        XCTAssertNotEqual(reports[0].0, reports[0].1)
    }

    func testDeletionIsDetected() throws {
        let path = try write("present", to: "binary")
        var reported = false
        let monitor = BundleReplacementMonitor(executablePath: path) { _, current in
            XCTAssertFalse(current.exists)
            reported = true
        }
        try FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(monitor.checkNow())
        XCTAssertTrue(reported)
    }

    func testTimerDetectsReplacementWithoutManualChecks() throws {
        let path = try write("version one", to: "binary")
        let fired = expectation(description: "monitor reported the swap")
        let monitor = BundleReplacementMonitor(executablePath: path) { _, _ in
            fired.fulfill()
        }
        monitor.start(interval: 0.05)
        defer { monitor.stop() }

        let staged = try write("version two", to: "staged")
        XCTAssertEqual(rename(staged, path), 0)

        wait(for: [fired], timeout: 5)
    }
}
