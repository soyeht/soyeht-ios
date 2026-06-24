import XCTest
@testable import SoyehtCore

/// E2d-1: behavioral coverage for the shared `ClawInventoryService` — the single
/// fetch + online-filter + install-completion poll the Store/drawer/provider will
/// adopt. Uses injected fetchers + an immediate sleeper; no network.
@MainActor
final class ClawInventoryServiceTests: XCTestCase {

    private let target = ClawMachineTarget.householdEndpoint(
        serverID: "srv", endpoint: URL(string: "https://198.51.100.10")!
    )

    // MARK: - Snapshot + online filter

    func test_refresh_buildsSnapshot_withOnlineFilterAndSort() async {
        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in [
                self.claw("Zeta", .succeeded, .creatable),     // installed
                self.claw("alpha", .succeeded, .creatable),    // installed
                self.claw("beta", .notInstalled, .notInstalled), // not installed
            ] },
            fetchInstances: { _ in [
                self.instance("Zeta", online: true),
                self.instance("alpha", online: true),
                self.instance("beta", online: true),   // online but not installed
            ] }
        )

        await service.refresh()

        XCTAssertEqual(service.snapshot.claws.count, 3)
        XCTAssertEqual(service.snapshot.onlineClawNames, ["Zeta", "alpha", "beta"])
        // deployed = installed AND online, name-sorted case-insensitively.
        XCTAssertEqual(service.snapshot.deployedOnlineClaws.map(\.name), ["alpha", "Zeta"])
        XCTAssertEqual(service.snapshot.installedCount, 2)
        XCTAssertEqual(service.snapshot.availableCount, 3)
        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isPolling, "No transient claws → no poll")
    }

    func test_refresh_excludesInstalledClawWithNoOnlineInstance() async {
        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in [self.claw("alpha", .succeeded, .creatable)] },
            fetchInstances: { _ in [self.instance("alpha", online: false)] }  // offline
        )
        await service.refresh()
        XCTAssertEqual(service.snapshot.deployedOnlineClaws, [], "Installed but offline → not deployed-online")
        XCTAssertTrue(service.snapshot.onlineClawNames.isEmpty)
    }

    func test_refresh_preservesLastKnownGoodOnError() async {
        let shouldThrow = Box(false)
        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in
                if shouldThrow.value { throw URLError(.timedOut) }
                return [self.claw("alpha", .succeeded, .creatable)]
            },
            fetchInstances: { _ in [self.instance("alpha", online: true)] }
        )

        await service.refresh()
        XCTAssertEqual(service.snapshot.deployedOnlineClaws.map(\.name), ["alpha"])

        shouldThrow.value = true
        await service.refresh()
        XCTAssertEqual(service.snapshot.deployedOnlineClaws.map(\.name), ["alpha"],
                       "On error the last-known-good snapshot is preserved")
        XCTAssertNotNil(service.errorMessage)
    }

    func test_refresh_toleratesInstancesFailure_publishesCatalog() async {
        // E2d-4b regression guard: the Store consumes ONLY the catalog (claws). An
        // `/instances` failure on first load must NOT blank the catalog — publish it
        // with an empty online projection and surface the error.
        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in [
                self.claw("alpha", .succeeded, .creatable),
                self.claw("beta", .notInstalled, .notInstalled),
            ] },
            fetchInstances: { _ in throw URLError(.timedOut) }
        )

        await service.refresh()

        XCTAssertEqual(service.snapshot.claws.map(\.name), ["alpha", "beta"],
                       "Catalog is published even when /instances fails")
        XCTAssertEqual(service.snapshot.availableCount, 2)
        XCTAssertTrue(service.snapshot.deployedOnlineClaws.isEmpty, "No instances → empty online projection")
        XCTAssertNotNil(service.errorMessage, "The instances error is surfaced")
    }

    func test_refresh_catalogFailure_keepsLastKnownGoodWholesale() async {
        // Symmetric: a CATALOG failure keeps the prior snapshot wholesale.
        let throwClaws = Box(false)
        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in
                if throwClaws.value { throw URLError(.timedOut) }
                return [self.claw("alpha", .succeeded, .creatable)]
            },
            fetchInstances: { _ in [self.instance("alpha", online: true)] }
        )
        await service.refresh()
        XCTAssertEqual(service.snapshot.claws.map(\.name), ["alpha"])

        throwClaws.value = true
        await service.refresh()
        XCTAssertEqual(service.snapshot.claws.map(\.name), ["alpha"],
                       "Catalog failure preserves last-known-good")
        XCTAssertNotNil(service.errorMessage)
    }

    // MARK: - Poll to terminal

    func test_poll_installingReachesInstalled_firesCompleteAndTerminal_thenStops() async {
        let clawResponses = Box([
            [self.claw("alpha", .installing, .installing(percent: 10))],  // refresh
            [self.claw("alpha", .succeeded, .creatable)],                 // first poll → terminal
        ])
        var completed: [(String, Bool)] = []
        var terminalCount = 0

        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in clawResponses.next() },
            fetchInstances: { _ in [self.instance("alpha", online: true)] },
            sleeper: { _ in },  // immediate
            onInstallComplete: { completed.append(($0, $1)) },
            onTerminalTransition: { terminalCount += 1 }
        )

        await service.refresh()
        XCTAssertTrue(service.isPolling, "An installing claw must start the poll")

        await waitUntil { !service.isPolling }

        XCTAssertEqual(completed.map(\.0), ["alpha"])
        XCTAssertEqual(completed.first?.1, true, "installed → success=true")
        XCTAssertEqual(terminalCount, 1, "Terminal transition fires exactly once")
        XCTAssertEqual(service.snapshot.claws.first?.installState, .installed)
    }

    func test_poll_installingReachesFailed_firesCompleteFalse() async {
        let clawResponses = Box([
            [self.claw("alpha", .installing, .installing(percent: 10))],
            [self.claw("alpha", .failed, .failed(error: "boom"))],
        ])
        var completed: [(String, Bool)] = []

        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in clawResponses.next() },
            fetchInstances: { _ in [] },
            sleeper: { _ in },
            onInstallComplete: { completed.append(($0, $1)) }
        )

        await service.refresh()
        await waitUntil { !service.isPolling }

        XCTAssertEqual(completed.map(\.0), ["alpha"])
        XCTAssertEqual(completed.first?.1, false, "installFailed → success=false")
    }

    /// The generation-guard race: a poll fetch starts, then a `refresh()` lands a
    /// newer snapshot (still transient, so the poll is NOT cancelled). When the
    /// in-flight poll fetch finally returns its now-STALE result, it must be
    /// dropped — not clobber the newer snapshot, not fire a terminal callback.
    /// Only the generation guard (not cancellation) can catch this case.
    func test_pollFetchSupersededByRefresh_isDroppedByGenerationGuard() async {
        let gate = PollGate()
        let tracker = CallTracker()
        var completed: [(String, Bool)] = []
        var terminalCount = 0

        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in
                switch await tracker.next() {
                case 1: return [self.claw("alpha", .installing, .installing(percent: 10))] // refresh #1
                case 2: await gate.arriveAndWait()                                          // poll fetch (gated)
                        return [self.claw("alpha", .succeeded, .creatable)]                 // STALE "installed"
                case 3: return [self.claw("alpha", .installing, .installing(percent: 20))]  // refresh #2 (still transient)
                default: return [self.claw("alpha", .succeeded, .creatable)]                // legit terminal
                }
            },
            fetchInstances: { _ in [self.instance("alpha", online: true)] },
            sleeper: { _ in },
            onInstallComplete: { completed.append(($0, $1)) },
            onTerminalTransition: { terminalCount += 1 }
        )

        await service.refresh()             // poll starts; poll fetch (#2) gates
        await gate.waitUntilArrived()       // #2 is in flight
        await service.refresh()             // #3: generation bumped, snapshot still transient → poll kept alive
        await gate.open()                   // #2 returns its stale "installed"
        await waitUntil { !service.isPolling }

        XCTAssertEqual(completed.count, 1,
            "The superseded poll fetch must be dropped; only the legit post-refresh poll fires onInstallComplete")
        XCTAssertEqual(completed.first?.1, true)
        XCTAssertEqual(terminalCount, 1, "Terminal fires once (from the legit poll), not from the stale one")
    }

    func test_noPoll_whenNothingTransient() async {
        let service = ClawInventoryService(
            target: target,
            fetchClaws: { _ in [self.claw("alpha", .succeeded, .creatable)] },
            fetchInstances: { _ in [self.instance("alpha", online: true)] },
            sleeper: { _ in }
        )
        await service.refresh()
        XCTAssertFalse(service.isPolling)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }

    private func claw(_ name: String, _ status: InstallStatus, _ overall: OverallState) -> Claw {
        Claw(
            name: name, description: "d", language: "rust", buildable: true,
            version: nil, binarySizeMb: nil, minRamMb: nil, license: nil, updatedAt: nil,
            availability: ClawAvailability(
                name: name,
                install: InstallProjection(status: status, progress: nil, installedAt: nil, error: nil, jobId: nil),
                host: HostProjection(coldPathReady: true, hasGolden: true, hasBaseRootfs: true, maintenanceBlocked: false, maintenanceRetryAfterSecs: nil),
                overall: overall, reasons: [], degradations: []
            ),
            installable: true
        )
    }

    private func instance(_ clawType: String, online: Bool) -> SoyehtInstance {
        SoyehtInstance(
            id: "i-\(clawType)", name: clawType, container: "c-\(clawType)",
            clawType: clawType, fqdn: nil, status: online ? .active : .stopped,
            port: nil, capabilities: nil,
            provisioningMessage: nil, provisioningPhase: nil, provisioningError: nil
        )
    }
}

/// Mutable reference holder for closure-captured test state.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// A one-shot gate that also reports when a waiter has arrived, so a test can
/// deterministically hold a poll fetch open while it triggers a refresh.
private actor PollGate {
    private var opened = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrived = false
    private var arrivedWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the gated fetch: marks arrival, then suspends until `open()`.
    func arriveAndWait() async {
        if !arrived {
            arrived = true
            arrivedWaiters.forEach { $0.resume() }
            arrivedWaiters.removeAll()
        }
        if opened { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func open() {
        opened = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }

    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivedWaiters.append($0) }
    }
}

/// Actor-serialized call counter so concurrent fetch closures get stable indices.
private actor CallTracker {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private extension Box where T == [[Claw]] {
    /// Returns the next response, repeating the last once exhausted.
    func next() -> [Claw] {
        guard !value.isEmpty else { return [] }
        return value.count == 1 ? value[0] : value.removeFirst()
    }
}
