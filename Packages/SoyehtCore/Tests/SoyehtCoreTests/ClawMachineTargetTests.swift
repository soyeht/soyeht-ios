import Foundation
import XCTest
@testable import SoyehtCore

final class ClawMachineTargetTests: XCTestCase {
    func testServerTargetBridgesToAPIAndCreateTargets() throws {
        let context = makeContext(id: "server-alpha", host: "linux-alpha.example.test")
        let target = ClawMachineTarget.server(context)

        XCTAssertEqual(target.serverID, "server-alpha")
        XCTAssertTrue(target.supportsDeploy)

        guard case .server(let apiContext) = target.apiTarget else {
            return XCTFail("Server machine target must bridge to ClawAPITarget.server")
        }
        XCTAssertEqual(apiContext.serverId, context.serverId)
        XCTAssertEqual(apiContext.token, context.token)

        guard case .server(let createContext) = target.createInstanceTarget else {
            return XCTFail("Server machine target must bridge to CreateInstanceTarget.server")
        }
        XCTAssertEqual(createContext.serverId, context.serverId)
        XCTAssertEqual(createContext.token, context.token)
    }

    func testHouseholdEndpointTargetCarriesServerIdentityAndEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://mac-alpha.example.test:8101"))
        let target = ClawMachineTarget.householdEndpoint(serverID: "mac-alpha-id", endpoint: endpoint)

        XCTAssertEqual(target.serverID, "mac-alpha-id")
        XCTAssertTrue(target.supportsDeploy)

        guard case .householdEndpoint(let apiEndpoint) = target.apiTarget else {
            return XCTFail("Household machine target must bridge to ClawAPITarget.householdEndpoint")
        }
        XCTAssertEqual(apiEndpoint, endpoint)

        guard case .householdEndpoint(let createEndpoint) = target.createInstanceTarget else {
            return XCTFail("Household machine target must bridge to CreateInstanceTarget.householdEndpoint")
        }
        XCTAssertEqual(createEndpoint, endpoint)
    }

    func testUnavailableTargetDoesNotProduceWireTargets() {
        let target = ClawMachineTarget.unavailable(.missingContext)

        XCTAssertNil(target.serverID)
        XCTAssertNil(target.apiTarget)
        XCTAssertNil(target.createInstanceTarget)
        XCTAssertFalse(target.supportsDeploy)
    }

    private func makeContext(id: String, host: String) -> ServerContext {
        let server = PairedServer(
            id: id,
            host: host,
            name: "server-alpha",
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
        return ServerContext(server: server, token: "token-alpha")
    }
}
