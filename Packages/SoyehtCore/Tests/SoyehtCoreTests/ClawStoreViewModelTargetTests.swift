import XCTest
import SoyehtCore

/// E2d-4 (identity): `ClawStoreViewModel` now keeps the canonical
/// `ClawMachineTarget` (which carries the serverID), not the lossy
/// `ClawAPITarget` that drops the serverID on `.householdEndpoint`. This is the
/// identity prerequisite for the Store VM adopting `ClawInventoryService`.
final class ClawStoreViewModelTargetTests: XCTestCase {

    func test_contextInit_storesServerMachineTarget() {
        let server = PairedServer(
            id: "srv-1", host: "api.example.test", name: "t",
            role: "admin", pairedAt: Date(), expiresAt: nil
        )
        let context = ServerContext(server: server, token: "tok")
        let vm = ClawStoreViewModel(context: context)
        XCTAssertEqual(vm.machineTarget, .server(context))
        XCTAssertEqual(vm.machineTarget.serverID, "srv-1")
    }

    func test_householdEndpointMachineTarget_preservesServerID() {
        // The point of E2d-4: `ClawAPITarget.householdEndpoint(URL)` drops the
        // serverID; `ClawMachineTarget.householdEndpoint(serverID:endpoint:)`
        // carries it, and the view model now keeps that canonical identity.
        let endpoint = URL(string: "https://198.51.100.10")!
        let vm = ClawStoreViewModel(
            machineTarget: .householdEndpoint(serverID: "srv-9", endpoint: endpoint)
        )
        XCTAssertEqual(vm.machineTarget, .householdEndpoint(serverID: "srv-9", endpoint: endpoint))
        XCTAssertEqual(vm.machineTarget.serverID, "srv-9",
                       "The serverID that the lossy ClawAPITarget would have dropped is preserved")
    }
}
