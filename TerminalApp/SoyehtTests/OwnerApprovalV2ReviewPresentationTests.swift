import XCTest

/// Source-guard tests for the approval-v2 review screen. The live passkey
/// sheet and app-target integration are CI-only, so these pin the contract
/// that keeps WYSIWYS, LocalAnchor trust, queue lifecycle, and v1 default
/// behavior intact.
final class OwnerApprovalV2ReviewPresentationTests: XCTestCase {
    func test_adapterRunsPinBeforeConfirmAndCompletesQueueLifecycle() throws {
        let source = try strippedIOSSource("Household/OwnerApprovalV2ReviewAdapter.swift")

        let begin = try position(of: "runtime.beginConfirming(request)", in: source)
        let claim = try position(of: "queue.claim(", in: source)
        let pin = try position(of: "try await pinAnchor(claimed)", in: source)
        let confirm = try position(of: "await reviewModel.confirm()", in: source)
        let terminal = try position(of: "queue.confirmClaim(", in: source)

        XCTAssertLessThan(begin, claim)
        XCTAssertLessThan(claim, pin)
        XCTAssertLessThan(pin, confirm)
        XCTAssertLessThan(confirm, terminal)

        XCTAssertTrue(source.contains("runtime.endConfirming(request.envelope.idempotencyKey)"))
        XCTAssertTrue(source.contains("guard !confirmInFlight else { return }"))
        XCTAssertTrue(source.contains("queue.failClaim("))
        XCTAssertTrue(source.contains("OwnerApprovalV2ReviewAdapterError.missingAnchorSecret"))
        XCTAssertTrue(source.contains("LocalAnchorClient(transport: transport).pinAnchor("))

        // approve-v2 subsumes the v1 approve(authorization) wire path, but it
        // does not subsume LocalAnchor. The adapter must never call the v1
        // approval client on the v2 path.
        XCTAssertFalse(source.contains("OwnerApprovalClient"))
        XCTAssertFalse(source.contains("approve(authorization"))
    }

    func test_reviewViewIsPhaseOnlyWYSIWYSAndDoesNotExposeOracleInputs() throws {
        let source = try strippedIOSSource("Household/OwnerApprovalV2ReviewScreen.swift")

        XCTAssertTrue(source.contains("adapter.phase"))
        XCTAssertTrue(source.contains("contextSection(context)"))
        XCTAssertTrue(source.contains("context.machineID"))
        XCTAssertTrue(source.contains("context.addr"))
        XCTAssertTrue(source.contains("context.transport"))
        XCTAssertTrue(source.contains("await adapter.prepare()"))
        XCTAssertTrue(source.contains("await adapter.confirm()"))

        // The context is rendered before the Approve action can call confirm.
        XCTAssertLessThan(
            try position(of: "contextSection(context)", in: source),
            try position(of: "await adapter.confirm()", in: source)
        )

        XCTAssertTrue(source.contains("\"approve\""))
        XCTAssertTrue(source.contains("\"try again\""))
        XCTAssertTrue(source.contains("\"cancel\""))

        XCTAssertFalse(source.contains("BootstrapError"))
        XCTAssertFalse(source.contains(".serverError"))
        XCTAssertFalse(source.contains(".code"))
        XCTAssertFalse(source.lowercased().contains("challenge"))
    }

    func test_runtimeKeepsApprovalV2ReviewDefaultOffAndPreservesV1Host() throws {
        let runtime = try strippedIOSSource("Household/HouseholdMachineJoinRuntime.swift")
        let home = try strippedIOSSource("Household/HouseholdHomeView.swift")

        XCTAssertTrue(runtime.contains("approvalV2ReviewEnabled: Bool = false"))
        XCTAssertTrue(runtime.contains("var isApprovalV2ReviewEnabled: Bool"))
        XCTAssertTrue(runtime.contains("OwnerApprovalV2ReviewViewModel(cursor: request.cursor"))

        let stack = try slice(
            home,
            from: "if machineJoinRuntime.isApprovalV2ReviewEnabled",
            to: "private struct OwnerApprovalV2ReviewCardHost"
        )
        XCTAssertTrue(stack.contains("OwnerApprovalV2ReviewCardHost("))
        XCTAssertTrue(stack.contains("else if let card = JoinRequestConfirmationCardHost("))
        XCTAssertTrue(stack.contains(".id(topId)"))
    }

    // MARK: helpers

    private func strippedIOSSource(_ relativePath: String) throws -> String {
        SourceCommentStripper.strip(try iosSource(relativePath))
    }

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func position(of needle: String, in source: String) throws -> String.Index {
        try XCTUnwrap(source.range(of: needle)?.lowerBound, "Missing source token: \(needle)")
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
