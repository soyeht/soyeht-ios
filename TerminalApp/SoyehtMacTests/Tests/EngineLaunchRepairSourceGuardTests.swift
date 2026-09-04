import XCTest
@testable import SoyehtMacDomain

/// `AppDelegate` is AppKit-bound, so the launch ordering that makes the two
/// repairs effective is pinned here from source, the way the other
/// launch-time guards are.
final class EngineLaunchRepairSourceGuardTests: XCTestCase {

    /// The owner-events repair has to run before the reconciler, which is the
    /// first thing at launch that can register, start, or bounce the engine.
    /// Repairing after it would leave a freshly started engine reading the
    /// old mode and failing Phase 3 one more time.
    func testOwnerEventsLogIsRepairedBeforeTheEngineCanStart() throws {
        let source = try macSource("AppDelegate.swift")
        let launch = try slice(
            source,
            from: "private func openInitialWindow() async {",
            to: "openWelcomeWindow()"
        )
        let repair = try XCTUnwrap(launch.range(of: "repairLegacyOwnerEventsLog()"))
        let reconcile = try XCTUnwrap(launch.range(of: "SMAppServiceInstaller.reconcileAtLaunch(isSetUp: isSetUp)"))
        XCTAssertLessThan(repair.lowerBound, reconcile.lowerBound)
        // Not gated on isSetUp: the file only exists on a set-up Mac, and the
        // repair reports .absent otherwise. Gating would just add a way to skip it.
        let beforeBranch = try slice(launch, from: "let isSetUp", to: "if isSetUp {")
        XCTAssertTrue(beforeBranch.contains("repairLegacyOwnerEventsLog()"))
    }

    func testRepairUsesTheProfileSupportDirectoryAndReportsEveryOutcome() throws {
        let source = try macSource("AppDelegate.swift")
        let helper = try slice(
            source,
            from: "private func repairLegacyOwnerEventsLog() {",
            to: "// MARK: - Bundle replacement guard"
        )
        XCTAssertTrue(helper.contains("OwnerEventsLogRepair.logURL(supportDirectory: EnginePackager.soyehtSupportDirectory)"))
        XCTAssertTrue(helper.contains("case .repaired(let previousMode):"))
        XCTAssertTrue(helper.contains("case .leftAlone(let reason):"))
        XCTAssertTrue(helper.contains("case .failed(let code):"))
    }

    /// A stale engine is only worth bouncing once the newer binary is staged
    /// in Application Support; otherwise the restart re-runs the same old
    /// engine and only costs the PTYs. And if staging fails there must be no
    /// restart at all.
    func testStaleEngineIsStagedBeforeItIsRestartedAndNeverRestartedOnStagingFailure() throws {
        let source = try macSource("AppDelegate.swift")
        let freshness = try slice(
            source,
            from: "private func verifyRunningEngineFreshness() {",
            to: "private func repairLegacyOwnerEventsLog() {"
        )
        let stage = try XCTUnwrap(freshness.range(of: "try EnginePackager.install()"))
        let restart = try XCTUnwrap(freshness.range(of: "SMAppServiceInstaller.restartStaleEngine()"))
        XCTAssertLessThan(stage.lowerBound, restart.lowerBound)
        XCTAssertEqual(freshness.components(separatedBy: "restartStaleEngine()").count - 1, 1)

        let failure = try slice(freshness, from: "} catch {", to: "SMAppServiceInstaller.restartStaleEngine()")
        XCTAssertTrue(failure.contains("return"), "a failed staging must leave the running engine alone")
        XCTAssertTrue(freshness.contains("guard verdict == .stale else { return }"))
    }

    /// A staged engine is restarted by launch only when nothing is attached to
    /// it. With sessions alive the restart is the person's decision, so the
    /// launch path must ask the process table first, restart only inside the
    /// `.restartNow` branch, and never from the branch that holds for the
    /// person. Measured 2026-09-03: without this, the update to 0.1.45 ended
    /// eight agent sessions one second after relaunch.
    func testAStaleEngineIsRestartedByLaunchOnlyOverNoLiveSessions() throws {
        let source = try macSource("AppDelegate.swift")
        let freshness = try slice(
            source,
            from: "private func verifyRunningEngineFreshness() {",
            to: "private func repairLegacyOwnerEventsLog() {"
        )
        let count = try XCTUnwrap(freshness.range(of: "SMAppServiceInstaller.liveBrokeredSessionCount"))
        let decision = try XCTUnwrap(freshness.range(of: "EngineServiceReconciler.staleEngineAction(liveSessionCount:"))
        let restart = try XCTUnwrap(freshness.range(of: "SMAppServiceInstaller.restartStaleEngine()"))
        XCTAssertLessThan(count.lowerBound, decision.lowerBound, "the table is read before the rule is applied")
        XCTAssertLessThan(decision.lowerBound, restart.lowerBound, "the rule is applied before anything restarts")

        let restartBranch = try slice(freshness, from: "case .restartNow:", to: "case .holdForPerson")
        XCTAssertTrue(restartBranch.contains("SMAppServiceInstaller.restartStaleEngine()"),
                      "the only launch-time restart lives in the branch that measured nothing alive")

        let holdStart = try XCTUnwrap(freshness.range(of: "case .holdForPerson"))
        let holdBranch = String(freshness[holdStart.lowerBound...])
        XCTAssertFalse(holdBranch.contains("restartStaleEngine"),
                       "with sessions alive, launch tells the person and restarts nothing")
        XCTAssertTrue(holdBranch.contains("EngineUpdateWindowController.present("),
                      "holding for the person means telling them, not only the log")
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
