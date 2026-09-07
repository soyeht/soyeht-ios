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
        let reconcile = try XCTUnwrap(launch.range(of: "await verifyRunningEngineFreshness()"))
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

    /// A dependency guard supplements the coordinator's behavioral tests:
    /// callers cannot stage/restart independently of its persisted decision.
    func testEntryPointsUseTheLifecycleWithoutLegacyRestartFallbacks() throws {
        for file in ["AppDelegate.swift", "Welcome/Bootstrap/InstallProgressView.swift", "Installer/SMAppServiceInstaller.swift"] {
            let source = try macSource(file)
            XCTAssertTrue(source.contains("EngineLifecycleService.run("), file)
            for obsolete in ["EnginePackager.install(", "restartStaleEngine(", "migrateOutOfTheGraphicalSessionIfQuiet(", "kickstart("] {
                XCTAssertFalse(source.contains(obsolete), "\(file) bypasses the replacement coordinator")
            }
        }
        let ui = try macSource("Installer/EngineUpdateWindowController.swift")
        XCTAssertTrue(ui.contains("case .legacyMigrationRequired(let original, let target):"))
        XCTAssertTrue(ui.contains("consent: .init(original: original, target: target)"))
        XCTAssertTrue(ui.contains("EngineLifecycleService.run(resume: resume, consent: consent)"))
        let menu = try macSource("MainMenu/MainMenuController.swift")
        XCTAssertTrue(menu.contains("func resumeEngineUpdate("))
        XCTAssertTrue(menu.contains("EngineLifecycleService.run(resume: true)"))
    }

    /// The window that carries the decision has to be answerable. MEASURED
    /// 2026-09-04 on the Dev build: an unbounded `maxHeight: .infinity` made
    /// the hosting view's fitting size 4224 points tall, so AppKit sized the
    /// window to it and both buttons sat far below the screen — the warning
    /// was readable and the answer was not reachable.
    func testEngineUpdateWindowIsSizedToItsContent() throws {
        let source = try macSource("Installer/EngineUpdateWindowController.swift")
        XCTAssertTrue(source.contains(".frame(width: 520)"))
        XCTAssertFalse(
            source.contains("maxHeight: .infinity"),
            "an unbounded height makes the window grow to thousands of points"
        )
        XCTAssertTrue(source.contains("window?.setContentSize(hosting.fittingSize)"))
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
