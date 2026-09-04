import XCTest
@testable import SoyehtMacDomain

/// The engine used to live in `gui/<uid>`, the graphical session, which
/// launchd tears down at logout. MEASURED 2026-09-04 on the owner's Mac: the
/// WindowServer exited at 07:47, loginwindow closed the session immediately,
/// and the engine died with it — every pane gone, after the whole promise of
/// the broker was that sessions outlive the app. On that same machine,
/// user-domain jobs (`secd`, `ctkd`, CoreSimulator) kept their PIDs straight
/// through the crash, some of them fifteen days old.
///
/// So the job moves to the user domain. These pin the two halves that can be
/// tested without launchd: WHEN the move is allowed to happen, and WHAT the
/// plist must say for launchd to put it there.
final class EngineSessionDomainTests: XCTestCase {

    // MARK: - When the move may happen

    func testMovesAtAQuietLaunch() {
        XCTAssertEqual(
            EngineServiceReconciler.sessionDomainAction(backgroundJobLoaded: false, liveSessionCount: 0),
            .migrateNow
        )
    }

    /// The move stops a running engine, and stopping it is exactly what costs
    /// panes. One attached session is enough to wait.
    func testWaitsWhileAnySessionIsAttached() {
        XCTAssertEqual(
            EngineServiceReconciler.sessionDomainAction(backgroundJobLoaded: false, liveSessionCount: 1),
            .waitForAQuietMoment(liveSessionCount: 1)
        )
        XCTAssertEqual(
            EngineServiceReconciler.sessionDomainAction(backgroundJobLoaded: false, liveSessionCount: 8),
            .waitForAQuietMoment(liveSessionCount: 8)
        )
    }

    /// A probe that could not answer is not a zero. This is the same rule
    /// that keeps a stale engine from being bounced blind, and it fails the
    /// same way: closed.
    func testAnUnreadableProcessTableIsNeverPermission() {
        XCTAssertEqual(
            EngineServiceReconciler.sessionDomainAction(backgroundJobLoaded: false, liveSessionCount: nil),
            .waitForAQuietMoment(liveSessionCount: nil)
        )
    }

    func testDoesNothingOnceTheJobIsAlreadyInTheUserDomain() {
        // Not even with sessions attached: there is nothing left to move, and
        // a "migration" here would be a pointless restart.
        XCTAssertEqual(
            EngineServiceReconciler.sessionDomainAction(backgroundJobLoaded: true, liveSessionCount: 4),
            .nothingToDo
        )
        XCTAssertEqual(
            EngineServiceReconciler.sessionDomainAction(backgroundJobLoaded: true, liveSessionCount: nil),
            .nothingToDo
        )
    }

    // MARK: - What the plist must say

    /// `LimitLoadToSessionType = Background` is the whole mechanism: launchd
    /// loads such a job into `user/<uid>` and REFUSES it in `gui/<uid>`.
    /// Both profiles ship it, or the profile without it keeps dying at logout.
    func testBothEngineJobsAskForTheBackgroundSession() throws {
        for name in ["com.soyeht.engine.plist", "com.soyeht.engine.dev.plist"] {
            let plist = try launchAgentPlist(name)
            XCTAssertEqual(
                plist["LimitLoadToSessionType"] as? String,
                "Background",
                "\(name) would load into the graphical session and die with the login"
            )
            // The rest of the job's shape must survive the edit: without
            // KeepAlive a crashed engine stays dead, and without RunAtLoad it
            // waits for an attach that never comes.
            XCTAssertEqual(plist["KeepAlive"] as? Bool, true, "\(name)")
            XCTAssertEqual(plist["RunAtLoad"] as? Bool, true, "\(name)")
        }
    }

    func testEachProfileKeepsItsOwnLabel() throws {
        XCTAssertEqual(
            try launchAgentPlist("com.soyeht.engine.plist")["Label"] as? String,
            "com.soyeht.engine"
        )
        XCTAssertEqual(
            try launchAgentPlist("com.soyeht.engine.dev.plist")["Label"] as? String,
            "com.soyeht.engine.dev"
        )
    }

    // MARK: - How the move is made

    /// The user domain has no plist directory of its own, and `bootstrap
    /// user/<uid>` wants root. `launchctl load -S Background` is the one
    /// interface that names a session type without asking for a password —
    /// losing it would either break the move or cost the zero-sudo install.
    func testTheJobIsLoadedWithAnExplicitBackgroundSessionType() throws {
        let source = try macSource("Installer/EngineBackgroundAgent.swift")
        XCTAssertTrue(source.contains(#"launchctl(["load", "-S", "Background", destination.path])"#))
        XCTAssertTrue(source.contains(#"launchctl(["print", "user/\(getuid())/\(label)"])"#))
    }

    /// Installing boots the label out of BOTH domains first: a `load` on a
    /// label that is still taken silently keeps the old command line, and the
    /// GUI job is precisely the one being replaced.
    func testInstallingFreesTheLabelInBothDomainsFirst() throws {
        let source = try macSource("Installer/EngineBackgroundAgent.swift")
        let install = try slice(source, from: "static func install(", to: "let load = launchctl")
        XCTAssertTrue(install.contains(#"launchctl(["bootout", "gui/\(getuid())/\(label)"])"#))
        XCTAssertTrue(install.contains(#"launchctl(["bootout", "user/\(getuid())/\(label)"])"#))
    }

    /// A launch that finds the job already home must not reload it: a reload
    /// restarts the engine, which is the cost the whole migration is timed to
    /// avoid.
    func testAnAlreadyMigratedLaunchRefreshesThePlistWithoutRestarting() throws {
        let source = try macSource("Installer/SMAppServiceInstaller.swift")
        let quiet = try slice(
            source,
            from: "case .nothingToDo:",
            to: "case .waitForAQuietMoment"
        )
        XCTAssertTrue(quiet.contains("write(to: destination, options: .atomic)"))
        XCTAssertFalse(quiet.contains("EngineBackgroundAgent.install("), "a reload here would take the panes")
        XCTAssertFalse(quiet.contains("restart("), "a reload here would take the panes")
    }

    /// The migration writes launchd state, so the same rule that governs the
    /// rest of launch has to hold here: nothing is written outside the branch
    /// that measured the cost. `.nothingToDo` and `.waitForAQuietMoment` may
    /// log and nothing else.
    func testOnlyTheMeasuredBranchWritesLaunchdState() throws {
        let source = try macSource("Installer/SMAppServiceInstaller.swift")
        let migration = try slice(
            source,
            from: "private static func migrateOutOfTheGraphicalSessionIfQuiet",
            to: "\n    }\n"
        )
        // The count is consulted before any branch is taken.
        let decision = try XCTUnwrap(migration.range(of: "sessionDomainAction("))
        let firstInstall = migration.range(of: "EngineBackgroundAgent.install(")
        XCTAssertTrue(
            firstInstall == nil || decision.lowerBound < firstInstall!.lowerBound,
            "the session count must be read before anything is installed"
        )
        let waiting = try slice(migration, from: "case .waitForAQuietMoment", to: "case .migrateNow")
        for line in waiting.split(separator: "\n").dropFirst() {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, !code.hasPrefix("//") else { continue }
            XCTAssertTrue(
                code.hasPrefix("reconcileLog.") || code == "}",
                "waiting may only log; found '\(code.prefix(60))'"
            )
        }
    }

    /// Uninstall has to clear both homes, or "start from scratch" leaves a
    /// job behind that comes back at the next login.
    func testUninstallClearsBothHomes() throws {
        let source = try macSource("Installer/SMAppServiceInstaller.swift")
        let unregister = try slice(source, from: "static func unregister() throws {", to: "\n    }")
        XCTAssertTrue(unregister.contains("EngineBackgroundAgent.remove(label: launchdLabel)"))
        XCTAssertTrue(unregister.contains("legacy.unregister()"))
    }

    // MARK: - Helpers

    private func launchAgentPlist(_ name: String) throws -> [String: Any] {
        let url = terminalAppDirectory()
            .appendingPathComponent("SoyehtMac/Library/LaunchAgents")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private func macSource(_ relativePath: String) throws -> String {
        let url = terminalAppDirectory()
            .appendingPathComponent("SoyehtMac")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func terminalAppDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
