import Foundation
import XCTest
@testable import SoyehtCore

@MainActor
final class ClawDeployMonitorTests: XCTestCase {
    func test_timeoutWhileStillProvisioningEndsAsCheckLaterNotFailure() async {
        let activity = RecordingDeployActivityManager()
        let notifications = RecordingDeployNotifications()
        let monitor = makeMonitor(
            activity: activity,
            notifications: notifications,
            status: InstanceStatusResponse(
                status: .provisioning,
                provisioningMessage: "booting",
                provisioningError: nil,
                provisioningPhase: "starting"
            )
        )

        monitor.monitor(
            instanceId: "inst-timeout",
            clawName: "picoclaw",
            clawType: "picoclaw",
            cpuCores: 2,
            ramMB: 2048,
            diskGB: 30,
            target: .server(makeContext())
        )

        await waitForMonitorToClear(monitor)

        XCTAssertEqual(activity.ended.last?.status, InstanceStatus.provisioning.rawValue)
        XCTAssertEqual(activity.ended.last?.message, ClawDeployMonitor.stillPreparingMessage)
        XCTAssertEqual(activity.ended.last?.phase, ClawDeployMonitor.checkLaterPhase)
        XCTAssertEqual(notifications.stillPreparing, ["picoclaw"])
        XCTAssertTrue(notifications.completed.isEmpty)
        XCTAssertTrue(monitor.activeDeploys.isEmpty)
    }

    func test_terminalFailedStatusStillPublishesFailure() async {
        let activity = RecordingDeployActivityManager()
        let notifications = RecordingDeployNotifications()
        let monitor = makeMonitor(
            activity: activity,
            notifications: notifications,
            status: InstanceStatusResponse(
                status: .failed,
                provisioningMessage: "boot failed",
                provisioningError: "boot failed",
                provisioningPhase: "starting"
            )
        )

        monitor.monitor(
            instanceId: "inst-failed",
            clawName: "picoclaw",
            clawType: "picoclaw",
            cpuCores: 2,
            ramMB: 2048,
            diskGB: 30,
            target: .server(makeContext())
        )

        await waitForMonitorToClear(monitor)

        XCTAssertEqual(activity.ended.last?.status, InstanceStatus.failed.rawValue)
        XCTAssertEqual(activity.ended.last?.message, "boot failed")
        XCTAssertNil(activity.ended.last?.phase)
        XCTAssertEqual(notifications.completed.map(\.clawName), ["picoclaw"])
        XCTAssertEqual(notifications.completed.map(\.success), [false])
        XCTAssertTrue(notifications.stillPreparing.isEmpty)
    }

    func test_terminalActiveStatusStillPublishesSuccess() async {
        let activity = RecordingDeployActivityManager()
        let notifications = RecordingDeployNotifications()
        let monitor = makeMonitor(
            activity: activity,
            notifications: notifications,
            status: InstanceStatusResponse(
                status: .active,
                provisioningMessage: nil,
                provisioningError: nil,
                provisioningPhase: nil
            )
        )

        monitor.monitor(
            instanceId: "inst-active",
            clawName: "picoclaw",
            clawType: "picoclaw",
            cpuCores: 2,
            ramMB: 2048,
            diskGB: 30,
            target: .server(makeContext())
        )

        await waitForMonitorToClear(monitor)

        XCTAssertEqual(activity.ended.last?.status, InstanceStatus.active.rawValue)
        XCTAssertNil(activity.ended.last?.message)
        XCTAssertNil(activity.ended.last?.phase)
        XCTAssertEqual(notifications.completed.map(\.clawName), ["picoclaw"])
        XCTAssertEqual(notifications.completed.map(\.success), [true])
        XCTAssertTrue(notifications.stillPreparing.isEmpty)
    }

    private func makeMonitor(
        activity: RecordingDeployActivityManager,
        notifications: RecordingDeployNotifications,
        status: InstanceStatusResponse
    ) -> ClawDeployMonitor {
        let monitor = ClawDeployMonitor(
            pollAttempts: 1,
            pollIntervalNanoseconds: 0,
            sleeper: { _ in },
            statusFetcher: { _, _ in status },
            notifyDeployComplete: { clawName, success in
                notifications.completed.append((clawName, success))
            },
            notifyDeployStillPreparing: { clawName in
                notifications.stillPreparing.append(clawName)
            }
        )
        monitor.activityManagerProvider = { activity }
        return monitor
    }

    private func waitForMonitorToClear(
        _ monitor: ClawDeployMonitor,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !monitor.activeDeploys.isEmpty {
            if Date() > deadline {
                XCTFail("Monitor still has active deploys", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeContext() -> ServerContext {
        ServerContext(
            server: PairedServer(
                id: "srv-alpha",
                host: "server-alpha.example.test",
                name: "server-alpha",
                role: "admin",
                pairedAt: Date(timeIntervalSince1970: 1_714_972_800),
                expiresAt: nil,
                platform: "linux",
                kind: .adminHost
            ),
            token: "TOKEN_EXAMPLE"
        )
    }
}

private final class RecordingDeployNotifications {
    var completed: [(clawName: String, success: Bool)] = []
    var stillPreparing: [String] = []
}

private final class RecordingDeployActivityManager: ClawDeployActivityManaging, @unchecked Sendable {
    struct Ended {
        let status: String
        let message: String?
        let phase: String?
    }

    var ended: [Ended] = []

    func startActivity(
        instanceId: String,
        clawName: String,
        clawType: String,
        cpuCores: Int,
        ramMB: Int,
        diskGB: Int
    ) {}

    func updateActivity(status: String, message: String?, phase: String?) {}

    func endActivity(status: String, message: String?, phase: String?) {
        ended.append(Ended(status: status, message: message, phase: phase))
    }
}
