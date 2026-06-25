import XCTest
@testable import SoyehtCore

/// Slice 3b view-model: `SharedAppsViewModel` drives the SHARED APPS screen via
/// the `OwnerGroupsReading` seam. Lab-tested with the stub reader + a failing
/// reader — no live engine, no SwiftUI.
@MainActor
final class SharedAppsViewModelTests: XCTestCase {
    private struct FailingReader: OwnerGroupsReading {
        struct Boom: Error {}
        func fetchOwnerGroups() async throws -> OwnerGroupsSnapshot { throw Boom() }
    }

    func testLoadFromStubSetsLoadedSnapshot() async {
        let vm = SharedAppsViewModel(reader: StubOwnerGroupsReader())
        await vm.load()
        XCTAssertEqual(vm.phase, .loaded)
        XCTAssertEqual(vm.snapshot.groups.count, 2)
        XCTAssertEqual(vm.snapshot.groups.first?.name, "Family")
        XCTAssertEqual(vm.snapshot.groups.first?.members.first?.label, "Dani")
    }

    func testLoadFailureSetsFailedPhase() async {
        let vm = SharedAppsViewModel(reader: FailingReader())
        await vm.load()
        guard case .failed = vm.phase else {
            return XCTFail("expected .failed phase")
        }
    }

    func testStartsInLoadingPhase() {
        let vm = SharedAppsViewModel(reader: StubOwnerGroupsReader())
        XCTAssertEqual(vm.phase, .loading)
        XCTAssertTrue(vm.snapshot.groups.isEmpty)
    }
}
