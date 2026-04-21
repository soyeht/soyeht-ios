import XCTest
import Foundation
@testable import SoyehtMacDomain

/// Regression coverage for the Welcome installer — specifically the three
/// behaviours PR #9 review called out (PR #9, issues P0 #1, #2, P1 #6):
///
///   - Install mode (`localhost` vs `tailscale`) must be propagated as
///     `--network <mode>` when the CLI accepts the flag, and must be
///     silently dropped when the CLI is older (so we don't wedge users on
///     the old Homebrew tap with an "unexpected argument" error).
///   - A defensive timeout sends SIGTERM when a subprocess never
///     terminates, surfacing `subprocessTimedOut` instead of hanging the
///     install flow indefinitely.
///   - `cancel()` terminates the in-flight child so closing the Welcome
///     window mid-install doesn't leave a `brew` / `soyeht` process
///     orphaned.
@MainActor
final class TheyOSInstallerTests: XCTestCase {

    // MARK: - buildStartArgs (pure)

    func test_buildStartArgs_localhostWithSupport_passesNetworkFlag() {
        let args = TheyOSInstaller.buildStartArgs(mode: .localhost, supportsNetworkFlag: true)
        XCTAssertEqual(args, ["start", "--yes", "--network", "localhost"],
                       "When CLI supports --network, localhost mode must be surfaced as a flag")
    }

    func test_buildStartArgs_tailscaleWithSupport_passesNetworkFlag() {
        let args = TheyOSInstaller.buildStartArgs(mode: .tailscale, supportsNetworkFlag: true)
        XCTAssertEqual(args, ["start", "--yes", "--network", "tailscale"],
                       "When CLI supports --network, tailscale mode must be surfaced as a flag")
    }

    func test_buildStartArgs_oldCliDropsFlag() {
        let localhostArgs = TheyOSInstaller.buildStartArgs(mode: .localhost, supportsNetworkFlag: false)
        let tailscaleArgs = TheyOSInstaller.buildStartArgs(mode: .tailscale, supportsNetworkFlag: false)
        XCTAssertEqual(localhostArgs, ["start", "--yes"],
                       "Old CLI must NOT receive --network — clap would reject the unknown arg")
        XCTAssertEqual(tailscaleArgs, ["start", "--yes"],
                       "Old CLI must NOT receive --network even for tailscale — user sees a warn in the log instead")
    }

    // MARK: - cancel() + timeout (integration against /bin/sleep)

    func test_cancel_terminatesRunningChild() async throws {
        let installer = TheyOSInstaller()

        // Fire a long sleep on a background task and yank the rug a moment
        // later. The runProcess call should throw `.cancelled` promptly
        // rather than waiting out the full sleep.
        let runTask = Task { [installer] in
            try await installer.runProcess("/bin/sleep", arguments: ["30"], label: "sleep")
        }
        // Give the subprocess a moment to actually launch before cancelling.
        try await Task.sleep(nanoseconds: 200_000_000)

        let started = CFAbsoluteTimeGetCurrent()
        installer.cancel()

        do {
            try await runTask.value
            XCTFail("runProcess should have thrown after cancel()")
        } catch let error as TheyOSInstallerError {
            guard case .cancelled = error else {
                XCTFail("Expected .cancelled, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected TheyOSInstallerError.cancelled, got \(error)")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertLessThan(elapsed, 5.0,
                          "cancel() must terminate the child promptly, not wait for the sleep to complete")
    }

    func test_timeout_sendsSIGTERMAndThrowsSubprocessTimedOut() async throws {
        let installer = TheyOSInstaller()

        let started = CFAbsoluteTimeGetCurrent()
        do {
            // 30s sleep, 1s timeout — timeout must fire first.
            try await installer.runProcess(
                "/bin/sleep",
                arguments: ["30"],
                label: "sleep",
                timeout: 1.0
            )
            XCTFail("runProcess should have thrown subprocessTimedOut")
        } catch let error as TheyOSInstallerError {
            guard case .subprocessTimedOut(let cmd, let seconds) = error else {
                XCTFail("Expected .subprocessTimedOut, got \(error)")
                return
            }
            XCTAssertEqual(cmd, "sleep")
            XCTAssertEqual(seconds, 1)
        } catch {
            XCTFail("Expected TheyOSInstallerError.subprocessTimedOut, got \(error)")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertLessThan(elapsed, 5.0,
                          "Timeout must actually fire at 1s — not wait for the 30s sleep to complete")
    }
}
