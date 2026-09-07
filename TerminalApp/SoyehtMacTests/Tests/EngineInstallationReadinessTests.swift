import XCTest
@testable import SoyehtMacDomain

@MainActor
final class EngineInstallationReadinessTests: XCTestCase {
    func testPendingDoesNotWakeRefusedPaneButConfirmedMigrationDoesBeforeDismissal() {
        let center = NotificationCenter()
        let originalGeneration = EngineInstallationReadiness.generation
        var observations = 0
        let observer = center.addObserver(forName: EngineInstallationReadiness.didBecomeReady,
                                          object: nil, queue: nil) { _ in
            observations += 1
        }
        defer { center.removeObserver(observer) }

        EngineInstallationReadiness.publish(.unconfirmed(.observationUnavailable), center: center)
        XCTAssertEqual(observations, 0)
        XCTAssertEqual(EngineInstallationReadiness.generation, originalGeneration)
        EngineInstallationReadiness.publish(.readyAfterLegacyMigration, center: center)
        XCTAssertEqual(observations, 1)
        XCTAssertNotEqual(EngineInstallationReadiness.generation, originalGeneration,
                          "an in-flight refusal must detect that its installation premise changed")
    }

    func testConfirmedServiceReadinessDoesNotDependOnContinuityClaim() {
        let center = NotificationCenter()
        var observations = 0
        let observer = center.addObserver(forName: EngineInstallationReadiness.didBecomeReady,
                                          object: nil, queue: nil) { _ in observations += 1 }
        defer { center.removeObserver(observer) }
        EngineInstallationReadiness.publish(.readyWithContinuity, center: center)
        EngineInstallationReadiness.publish(.readyAfterSupervisorRestart, center: center)
        EngineInstallationReadiness.publish(.readyNoReplacement, center: center)
        XCTAssertEqual(observations, 3)
    }
}
