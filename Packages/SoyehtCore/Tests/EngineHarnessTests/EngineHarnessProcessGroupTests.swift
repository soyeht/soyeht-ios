import Darwin
import Foundation
import XCTest

final class EngineHarnessProcessGroupTests: XCTestCase {
    func testTeardownKillsChildAndGrandchildAfterLeaderExits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-engine-harness-process-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidFile = directory.appendingPathComponent("descendants.pid")
        let leader = try launchTermIgnoringDescendantGroup(pidFile: pidFile)
        let processGroupID = leader.processIdentifier
        var needsCleanup = true
        defer {
            if needsCleanup {
                EngineHarness.terminateProcessGroup(
                    leader,
                    processGroupID: processGroupID,
                    gracePeriod: 0
                )
            }
        }

        let descendants = try waitForDescendantPIDs(at: pidFile)
        guard Darwin.getpgid(descendants.child) == processGroupID,
              Darwin.getpgid(descendants.grandchild) == processGroupID else {
            XCTFail("Fixture descendants did not join the leader process group.")
            return
        }

        // The leader accepts SIGTERM, while both descendants deliberately
        // ignore it. Put the fixture into the exact regression state: the
        // leader has exited but its process group still owns live descendants.
        _ = Darwin.kill(-processGroupID, SIGTERM)
        guard waitForLeaderExit(leader) else {
            XCTFail("Fixture leader did not exit after SIGTERM.")
            return
        }
        guard processExists(descendants.child), processExists(descendants.grandchild) else {
            XCTFail("Fixture descendants did not survive SIGTERM as expected.")
            return
        }

        EngineHarness.terminateProcessGroup(
            leader,
            processGroupID: processGroupID,
            gracePeriod: 0
        )

        guard !leader.isRunning else {
            XCTFail("Fixture leader survived process-group teardown.")
            return
        }
        guard waitForProcessExit(descendants.child) else {
            XCTFail("Child survived process-group teardown after leader exit.")
            return
        }
        guard waitForProcessExit(descendants.grandchild) else {
            XCTFail("Grandchild survived process-group teardown after leader exit.")
            return
        }
        needsCleanup = false
    }

    private func launchTermIgnoringDescendantGroup(pidFile: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-MPOSIX=setsid",
            "-e",
            """
            setsid() or die "setsid failed";
            my $pid_file = shift @ARGV;
            my $child = fork();
            defined $child or die "child fork failed";
            if ($child == 0) {
                $SIG{TERM} = 'IGNORE';
                my $grandchild = fork();
                defined $grandchild or die "grandchild fork failed";
                if ($grandchild == 0) {
                    $SIG{TERM} = 'IGNORE';
                    sleep 30;
                    exit 0;
                }
                open my $file, '>', $pid_file or die "pid file open failed";
                print {$file} "$$ $grandchild";
                close $file or die "pid file close failed";
                sleep 30;
                exit 0;
            }
            sleep 30;
            """,
            pidFile.path,
        ]
        try process.run()
        return process
    }

    private func waitForDescendantPIDs(at pidFile: URL) throws -> (child: pid_t, grandchild: pid_t) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8) {
                let pids = contents
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { pid_t(String($0)) }
                if pids.count == 2 {
                    return (pids[0], pids[1])
                }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw FixtureError.descendantPIDsNotWritten
    }

    private func waitForProcessExit(_ processID: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !processExists(processID) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return !processExists(processID)
    }

    private func waitForLeaderExit(_ leader: Process) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while leader.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        return !leader.isRunning
    }

    private func processExists(_ processID: pid_t) -> Bool {
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private enum FixtureError: Error {
        case descendantPIDsNotWritten
    }
}
