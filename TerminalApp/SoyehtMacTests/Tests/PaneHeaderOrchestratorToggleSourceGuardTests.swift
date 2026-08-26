import XCTest

final class PaneHeaderOrchestratorToggleSourceGuardTests: XCTestCase {
    func testVisibleHeaderReplacesIPhoneControlWithOrchestratorToggleBeforeSplits() throws {
        let source = try macSource("PaneGrid/PaneHeaderView.swift")
        let stack = try slice(
            source,
            from: "private lazy var buttonsStack",
            to: "private var copiedIndicatorHideWorkItem"
        )

        XCTAssertTrue(stack.contains("orchestrationManagerChip"))
        XCTAssertTrue(stack.contains("splitVChip"))
        XCTAssertTrue(stack.contains("splitHChip"))
        XCTAssertFalse(stack.contains("openOnIPhoneChip"))
        XCTAssertLessThan(
            try XCTUnwrap(stack.range(of: "orchestrationManagerChip")?.lowerBound),
            try XCTUnwrap(stack.range(of: "splitVChip")?.lowerBound)
        )
    }

    func testToggleUsesExistingUserOwnedWorkspaceAuthorization() throws {
        let header = try macSource("PaneGrid/PaneHeaderView.swift")
        let controller = try macSource("PaneGrid/PaneViewController+AgentSettings.swift")

        XCTAssertTrue(header.contains("onOrchestrationManagerToggleRequested"))
        XCTAssertTrue(header.contains("button.setButtonType(.toggle)"))
        XCTAssertTrue(controller.contains("orchestration.setManagementAuthorization("))
        XCTAssertTrue(controller.contains("workspaceStore.flushPendingSave()"))
        XCTAssertTrue(controller.contains("previousOrchestration"))
        XCTAssertTrue(controller.contains("hasAuthenticatedAgentRuntime"))
        XCTAssertFalse(controller.contains("convStore.updateFields(\n            conversation.id,\n            handle: conversation.handle,\n            agent:"))
    }

    func testRetiredIPhoneHeaderCodeIsExplicitlyMarkedForSafeRemoval() throws {
        let accessories = try macSource("PaneGrid/PaneContentViewControlling.swift")
        let header = try macSource("PaneGrid/PaneHeaderView.swift")

        XCTAssertTrue(header.contains("TODO(remove-open-on-iphone-header-code)"))
        XCTAssertFalse(accessories.contains(
            "terminalDefault: PaneHeaderAccessories = [.qr, .openOnIPhone]"
        ))
        XCTAssertTrue(accessories.contains(
            "terminalDefault: PaneHeaderAccessories = [.qr, .orchestrationManager]"
        ))
    }

    func testManualRuntimeTransitionsRevokePaneOrchestratorPrivilege() throws {
        let router = try macSource(
            "App/SoyehtAutomationRequestRouter+07DirectoryIdentity.swift"
        )
        let claim = try slice(
            router,
            from: "func handleClaimAgentRuntime(",
            to: "func handleReleaseAgentRuntime("
        )
        let release = try slice(
            router,
            from: "func handleReleaseAgentRuntime(",
            to: "/// Creation requests"
        )

        XCTAssertTrue(claim.contains(
            "previousRuntimeClaim?.instanceID != runtimeInstanceID"
        ))
        XCTAssertTrue(claim.contains(
            "revokeShellRuntimeOrchestrationAuthorization(for: source)"
        ))
        XCTAssertLessThan(
            try XCTUnwrap(claim.range(
                of: "revokeShellRuntimeOrchestrationAuthorization(for: source)"
            )?.lowerBound),
            try XCTUnwrap(claim.range(
                of: "claimRuntimeIdentity("
            )?.lowerBound)
        )
        XCTAssertTrue(release.contains(
            "revokeShellRuntimeOrchestrationAuthorization(for: source)"
        ))
        XCTAssertLessThan(
            try XCTUnwrap(release.range(
                of: "revokeShellRuntimeOrchestrationAuthorization(for: source)"
            )?.lowerBound),
            try XCTUnwrap(release.range(
                of: "releaseRuntimeIdentity("
            )?.lowerBound)
        )
    }

    func testImplicitRuntimeAdoptionRevokesThePreviousInstanceGrant() throws {
        let router = try macSource(
            "App/SoyehtAutomationRequestRouter+07DirectoryIdentity.swift"
        )
        let authentication = try slice(
            router,
            from: "func authenticatesAutomationSource(",
            to: "func resolveAutomationSource("
        )
        let preflight = try XCTUnwrap(authentication.range(of: "canClaimRuntimeIdentity("))
        let revoke = try XCTUnwrap(authentication.range(
            of: "revokeShellRuntimeOrchestrationAuthorization(for: source)"
        ))
        let claim = try XCTUnwrap(authentication.range(of: "claimRuntimeIdentity("))
        let accepted = try XCTUnwrap(authentication.range(
            of: "runtimeIdentityIsValid = true"
        ))

        XCTAssertLessThan(preflight.lowerBound, revoke.lowerBound)
        XCTAssertLessThan(revoke.lowerBound, claim.lowerBound)
        XCTAssertLessThan(claim.lowerBound, accepted.lowerBound)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
