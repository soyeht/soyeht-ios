import XCTest

/// Guards for "Forget this home" (S10).
///
/// The contracts, in English:
///
/// 1. The alert has two buttons and the destructive one is not the default.
///    This is the last place someone can change their mind about a household
///    this Mac cannot get back.
/// 2. The copy says what it does *and* what it does not: files and terminals
///    untouched, and the home stays alive on any iPhone that still has it.
///    The Mac holds no owner key on the ordinary route, so it cannot revoke
///    for everyone and must not imply that it did.
/// 3. The service's order is the whole point. Stop the engine before deleting
///    its files, delete the credential rows before the id that points at
///    them, and never let a refused remote revocation abort the local forget
///    — otherwise the Mac stays wedged in a home whose only key is gone.
/// 4. Nothing here starts an engine. `kickstart` belongs to the installer.
final class ForgetHomeSourceGuardTests: XCTestCase {

    func test_theAlertOffersTwoChoicesAndDoesNotDefaultToTheDestructiveOne() throws {
        let prefs = try codeOnly(macSource("PreferencesDevicesViewController.swift"))
        let action = try slice(prefs, from: "@objc private func forgetThisHome()", to: "@objc private func joinExistingSoyeht()")

        XCTAssertEqual(action.components(separatedBy: "alert.addButton(withTitle:").count - 1, 2)
        XCTAssertTrue(action.contains("prefs.devices.forgetHome.alert.confirm"))
        XCTAssertTrue(action.contains("prefs.devices.forgetHome.alert.cancel"))
        XCTAssertTrue(action.contains("alert.buttons.first?.hasDestructiveAction = true"))
        XCTAssertTrue(action.contains("guard alert.runModal() == .alertFirstButtonReturn else { return }"))
        // A default destructive button turns a stray Return into a wiped home.
        XCTAssertFalse(action.contains("keyEquivalent = \"\\r\""))
    }

    func test_theCopySaysWhatItDoesNotDoEither() throws {
        let prefs = try macSource("PreferencesDevicesViewController.swift")
        let body = try slice(prefs, from: "prefs.devices.forgetHome.alert.body", to: "comment:")

        XCTAssertTrue(body.contains("files and terminals are untouched"))
        XCTAssertTrue(body.lowercased().contains("iphone that still has this home"))
        // "Start over" said nothing about scope and opened the uninstaller.
        XCTAssertFalse(prefs.contains("prefs.devices.startOver"))
        XCTAssertFalse(prefs.contains("AppDelegate.uninstallSoyeht"))
    }

    func test_theOrderOfTheForgetIsTheOrderThatSurvivesAFailure() throws {
        let service = try codeOnly(macSource("Welcome/ForgetHomeService.swift"))
        let run = try slice(service, from: "func run() async -> Outcome", to: "static func revokeRemotelyIfSignable")

        let steps = [
            "revokeRemotely(household)",
            "unregisterLoginItem()",
            "await stopServices()",
            "await resetLocalEngineState()",
            "forgetLocalServers()",
            "clearHouseholdSession()",
            "revokeLocalPairings()",
            "reopenWelcome()"
        ]
        var cursor = run.startIndex
        for step in steps {
            let found = try XCTUnwrap(
                run.range(of: step, range: cursor..<run.endIndex),
                "\(step) is missing or out of order in ForgetHomeService.run()"
            )
            cursor = found.upperBound
        }

        // The remote revocation is a `Bool`, not a `throw`: on the ordinary
        // route this Mac has no owner key and the engine refuses. That is an
        // outcome to report, never a reason to leave the Mac in the home.
        XCTAssertTrue(service.contains("var revokeRemotely: (ActiveHouseholdState) async -> Bool"))
        XCTAssertTrue(run.contains("var revokedRemotely = false"))
        XCTAssertFalse(run.contains("try revokeRemotely"))
        XCTAssertFalse(run.contains("guard revokedRemotely"))

        // The dangling verified-server id goes with the row it points at.
        XCTAssertTrue(service.contains("clearVerifiedServerID()"))
        // Forgetting a home never starts an engine.
        XCTAssertFalse(service.contains("kickstart"))
        XCTAssertFalse(service.contains("SMAppServiceInstaller.register()"))
    }

    func test_everyStepIsInjectableSoTheOrderCanBeTestedWithoutWipingAMac() throws {
        let service = try codeOnly(macSource("Welcome/ForgetHomeService.swift"))
        for closure in [
            "var loadHousehold: () -> ActiveHouseholdState?",
            "var unregisterLoginItem: () throws -> Void",
            "var stopServices: () async -> Void",
            "var resetLocalEngineState: () async -> Void",
            "var forgetLocalServers: () -> Void",
            "var clearHouseholdSession: () -> Void",
            "var reopenWelcome: () -> Void"
        ] {
            XCTAssertTrue(service.contains(closure), "not injectable: \(closure)")
        }
    }

    // MARK: - Helpers

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return false }
                if trimmed.hasPrefix("*") { return false }
                if trimmed.hasPrefix("/*") { return false }
                return true
            }
            .joined(separator: "\n")
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
