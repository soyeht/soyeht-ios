import XCTest
import SoyehtCore
@testable import Soyeht

@MainActor
final class OwnerEventsCoordinatorTests: XCTestCase {
    func testForegroundStartsLongPoll() async throws {
        let probe = OwnerEventsRunProbe()
        let coordinator = OwnerEventsCoordinator {
            try await probe.runUntilCancelled()
        }

        coordinator.enterForeground()
        await probe.waitForStarts(1)

        XCTAssertEqual(coordinator.state, .foregroundRunning)

        coordinator.enterBackground()
        await probe.waitForCancellations(1)
    }

    func testRepeatedForegroundDoesNotStartDuplicatePollers() async throws {
        let probe = OwnerEventsRunProbe()
        let coordinator = OwnerEventsCoordinator {
            try await probe.runUntilCancelled()
        }

        coordinator.enterForeground()
        await probe.waitForStarts(1)
        coordinator.enterForeground()
        try await Task.sleep(nanoseconds: 20_000_000)

        let starts = await probe.currentStarts()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(coordinator.state, .foregroundRunning)

        coordinator.enterBackground()
        await probe.waitForCancellations(1)
    }

    func testBackgroundSuspendsAndForegroundRestartsLongPoll() async throws {
        let probe = OwnerEventsRunProbe()
        let coordinator = OwnerEventsCoordinator {
            try await probe.runUntilCancelled()
        }

        coordinator.enterForeground()
        await probe.waitForStarts(1)

        coordinator.enterBackground()
        await probe.waitForCancellations(1)
        XCTAssertEqual(coordinator.state, .suspended)

        coordinator.enterForeground()
        await probe.waitForStarts(2)
        XCTAssertEqual(coordinator.state, .foregroundRunning)

        coordinator.enterBackground()
        await probe.waitForCancellations(2)
    }

    func testForegroundPollFailureSurfacesTypedError() async throws {
        let probe = OwnerEventsRunProbe(errorToThrow: .protocolViolation(detail: .unexpectedResponseShape))
        let coordinator = OwnerEventsCoordinator {
            try await probe.runAndFail()
        }

        coordinator.enterForeground()
        await probe.waitForStarts(1)
        try await waitForState(.failed(.protocolViolation(detail: .unexpectedResponseShape)), coordinator: coordinator)

        XCTAssertEqual(coordinator.lastError, .protocolViolation(detail: .unexpectedResponseShape))
    }

    func testAPNSTickleTriggersOneBackgroundFetch() async throws {
        let center = NotificationCenter()
        let probe = OwnerEventsRunProbe()
        let coordinator = OwnerEventsCoordinator(
            foregroundRun: {},
            backgroundFetch: {
                try await probe.runOnce()
            },
            notificationCenter: center
        )

        center.post(name: .soyehtHouseholdAPNSTickle, object: nil)
        await probe.waitForStarts(1)
        try await waitForState(.suspended, coordinator: coordinator)

        let starts = await probe.currentStarts()
        XCTAssertEqual(starts, 1)
    }

    func testAPNSTickleDoesNotStartBackgroundFetchWhileForegroundPollRuns() async throws {
        let center = NotificationCenter()
        let foregroundProbe = OwnerEventsRunProbe()
        let backgroundProbe = OwnerEventsRunProbe()
        let coordinator = OwnerEventsCoordinator(
            foregroundRun: {
                try await foregroundProbe.runUntilCancelled()
            },
            backgroundFetch: {
                try await backgroundProbe.runOnce()
            },
            notificationCenter: center
        )

        coordinator.enterForeground()
        await foregroundProbe.waitForStarts(1)
        center.post(name: .soyehtHouseholdAPNSTickle, object: nil)
        try await Task.sleep(nanoseconds: 20_000_000)

        let backgroundStarts = await backgroundProbe.currentStarts()
        XCTAssertEqual(backgroundStarts, 0)
        XCTAssertEqual(coordinator.state, .foregroundRunning)

        coordinator.enterBackground()
        await foregroundProbe.waitForCancellations(1)
    }

    func testAPNSIntegrityErrorDoesNotTriggerBackgroundFetch() async throws {
        let center = NotificationCenter()
        let probe = OwnerEventsRunProbe()
        let coordinator = OwnerEventsCoordinator(
            foregroundRun: {},
            backgroundFetch: {
                try await probe.runOnce()
            },
            notificationCenter: center
        )

        center.post(
            name: .soyehtHouseholdAPNSIntegrityError,
            object: APNSOpaqueTickleError.forbiddenPayloadKey("hh_id")
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        let starts = await probe.currentStarts()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(coordinator.state, .suspended)
    }

    private func waitForState(
        _ expected: OwnerEventsCoordinator.State,
        coordinator: OwnerEventsCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if coordinator.state == expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for state \(expected); current state is \(coordinator.state)", file: file, line: line)
    }
}

actor OwnerEventsRunProbe {
    private let errorToThrow: MachineJoinError
    private var starts = 0
    private var cancellations = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(errorToThrow: MachineJoinError = .networkDrop) {
        self.errorToThrow = errorToThrow
    }

    func runUntilCancelled() async throws {
        starts += 1
        resumeSatisfiedStartWaiters()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            cancellations += 1
            resumeSatisfiedCancellationWaiters()
            throw error
        }
    }

    func runAndFail() async throws {
        starts += 1
        resumeSatisfiedStartWaiters()
        throw errorToThrow
    }

    func runOnce() async throws {
        starts += 1
        resumeSatisfiedStartWaiters()
    }

    func waitForStarts(_ target: Int) async {
        guard starts < target else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((target, continuation))
        }
    }

    func waitForCancellations(_ target: Int) async {
        guard cancellations < target else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((target, continuation))
        }
    }

    func currentStarts() -> Int {
        starts
    }

    private func resumeSatisfiedStartWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in startWaiters {
            if starts >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        startWaiters = pending
    }

    private func resumeSatisfiedCancellationWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in cancellationWaiters {
            if cancellations >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        cancellationWaiters = pending
    }
}
