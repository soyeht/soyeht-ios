import XCTest

final class DevicePairApprovalPresentationTests: XCTestCase {
    func test_instanceListRendersDevicePairApprovalOverlay() throws {
        let source = try iosSource("SSHLoginView.swift")
        let instanceListBranch = try slice(
            source,
            from: "case .instanceList:",
            to: "case .terminal"
        )

        XCTAssertTrue(instanceListBranch.contains("HouseholdDevicePairRequestOverlay"))
        XCTAssertTrue(instanceListBranch.contains("activeHousehold"))
        XCTAssertTrue(instanceListBranch.contains("machineJoinRuntime"))
    }

    func test_householdHomeSharesDevicePairApprovalOverlay() throws {
        let source = try iosSource("Household/HouseholdHomeView.swift")
        let homeView = try slice(
            source,
            from: "struct HouseholdHomeView: View",
            to: "struct HouseholdDevicePairRequestOverlay: View"
        )
        let overlay = try slice(
            source,
            from: "struct HouseholdDevicePairRequestOverlay: View",
            to: "/// Compact summary"
        )

        XCTAssertTrue(homeView.contains("HouseholdDevicePairRequestOverlay("))
        XCTAssertTrue(overlay.contains("pendingDevicePairRequests"))
        XCTAssertTrue(overlay.contains("confirmingDevicePairRequest"))
        XCTAssertTrue(overlay.contains("DevicePairConfirmationCardHost"))
    }

    func test_existingHouseSetupDefersLocalMacPairingUntilHouseholdPairingSucceeds() throws {
        let source = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let claimHandler = try slice(
            source,
            from: "publisher.onMacClaimed",
            to: "func stop()"
        )
        let connectFlow = try slice(
            source,
            from: "func connectToExistingHouse()",
            to: "// MARK: - Private"
        )

        XCTAssertTrue(claimHandler.contains("claim.macLocalPairing, claim.existingHouse == nil"))
        XCTAssertTrue(claimHandler.contains("deferredLocalPairing: claim.macLocalPairing"))
        XCTAssertTrue(connectFlow.contains("if let pairing = house.deferredLocalPairing"))
        XCTAssertTrue(connectFlow.contains("installMacLocalPairing(pairing)"))
    }

    func test_machineJoinRuntimeSnapshotsQueuesAfterSubscribingToStreams() throws {
        let source = try iosSource("Household/HouseholdMachineJoinRuntime.swift")
        let joinObserver = try slice(
            source,
            from: "private func observeQueue()",
            to: "private func observeDevicePairQueue()"
        )
        let devicePairObserver = try slice(
            source,
            from: "private func observeDevicePairQueue()",
            to: "private func refreshPendingRequests()"
        )

        XCTAssertTrue(joinObserver.contains("let stream = await queue.events()"))
        XCTAssertTrue(joinObserver.contains("let initialRequests = await queue.pendingRequests"))
        XCTAssertTrue(joinObserver.contains("for await _ in stream"))
        XCTAssertTrue(devicePairObserver.contains("let stream = await devicePairQueue.events()"))
        XCTAssertTrue(devicePairObserver.contains("let initialRequests = await devicePairQueue.pendingRequests"))
        XCTAssertTrue(devicePairObserver.contains("for await _ in stream"))
    }

    func test_macExistingHouseSetupUsesDirectNotificationPath() throws {
        let source = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let listenFlow = try slice(
            source,
            from: "func listen() async -> Outcome",
            to: "private func listenViaBonjour()"
        )
        let directFlow = try slice(
            source,
            from: "private func listenViaTailscalePeerProbe()",
            to: "private final class ResumeOnce"
        )

        XCTAssertTrue(listenFlow.contains("if existingHouse != nil"))
        XCTAssertTrue(listenFlow.contains("return await listenViaTailscalePeerProbe()"))
        XCTAssertTrue(directFlow.contains("findFirstInvitation("))
        XCTAssertFalse(source.contains("ignoredDeviceIDs.contains(deviceID)"))
        XCTAssertFalse(directFlow.contains("try? await SetupInvitationDirectProbe.notifyClaimed"))
        XCTAssertTrue(directFlow.contains("try await SetupInvitationDirectProbe.notifyClaimed"))
    }

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
