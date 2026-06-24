import XCTest
@testable import SoyehtCore

/// E2d-4b: `ClawStoreViewModel` now delegates its catalog fetch + install-
/// completion poll to the shared `ClawInventoryService`. These tests verify the
/// adoption via an injected service with fake fetchers (no network).
@MainActor
final class ClawStoreViewModelServiceAdoptionTests: XCTestCase {

    private let target = ClawMachineTarget.householdEndpoint(
        serverID: "s", endpoint: URL(string: "https://198.51.100.10")!
    )

    func test_loadClaws_mirrorsServiceCatalogSnapshot() async {
        let vm = ClawStoreViewModel(
            machineTarget: target,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in [self.claw("alpha", .notInstalled, .notInstalled),
                                        self.claw("beta", .succeeded, .creatable)] },
                    fetchInstances: { _ in [] },
                    sleeper: { _ in },
                    autoPoll: false
                )
            }
        )
        await vm.loadClaws()
        XCTAssertEqual(vm.claws.map(\.name), ["alpha", "beta"], "claws mirror the service snapshot catalog")
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isPolling, "No transient claw → no poll")
    }

    func test_loadClaws_preservesLastKnownGoodOnError() async {
        let shouldThrow = Box(false)
        let vm = ClawStoreViewModel(
            machineTarget: target,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in
                        if shouldThrow.value { throw URLError(.timedOut) }
                        return [self.claw("alpha", .succeeded, .creatable)]
                    },
                    fetchInstances: { _ in [] },
                    sleeper: { _ in },
                    autoPoll: false
                )
            }
        )
        await vm.loadClaws()
        XCTAssertEqual(vm.claws.map(\.name), ["alpha"])

        shouldThrow.value = true
        await vm.loadClaws()
        XCTAssertEqual(vm.claws.map(\.name), ["alpha"], "Catalog preserved on error")
        XCTAssertNotNil(vm.errorMessage)
    }

    func test_installingClawReachesTerminal_firesOnInstallComplete_andStopsPolling() async {
        let tracker = CallTracker()
        var completed: [(String, Bool)] = []
        let vm = ClawStoreViewModel(
            machineTarget: target,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in
                        switch await tracker.next() {
                        case 1: return [self.claw("alpha", .installing, .installing(percent: 10))]  // load → poll starts
                        default: return [self.claw("alpha", .succeeded, .creatable)]                // poll → terminal
                        }
                    },
                    fetchInstances: { _ in [] },
                    sleeper: { _ in },
                    autoPoll: true,
                    onInstallComplete: { completed.append(($0, $1)) }
                )
            }
        )

        await vm.loadClaws()
        XCTAssertTrue(vm.isPolling, "An installing claw starts the poll")

        await waitUntil { !vm.isPolling }
        XCTAssertEqual(completed.map(\.0), ["alpha"])
        XCTAssertEqual(completed.first?.1, true, "installed → success")
        XCTAssertEqual(vm.claws.first?.installState, .installed)
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
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private actor CallTracker {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
