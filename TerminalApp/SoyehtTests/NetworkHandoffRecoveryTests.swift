import XCTest
@testable import Soyeht

/// Measured 2026-09-02 07:04 on the iPhone leaving Wi-Fi with 5G and the
/// tailnet still up: the open terminal was dismissed within seconds and the
/// session list sat on "The Internet connection appears to be offline" until
/// a manual retry. Both recoveries are decided by the pure helpers pinned here.
final class NetworkHandoffRecoveryTests: XCTestCase {

    // MARK: - Session list: a Wi-Fi → cellular handoff keeps the path satisfied

    func testAnySatisfiedPathUpdateAfterTheFirstWarrantsAReload() {
        // Initial monitor state: the `.task` load already covers it.
        XCTAssertFalse(WorkspaceListReloadPolicy.pathUpdateWarrantsReload(satisfied: true, previouslySatisfied: nil))
        // Wi-Fi → cellular: satisfied before, satisfied after, route changed.
        XCTAssertTrue(WorkspaceListReloadPolicy.pathUpdateWarrantsReload(satisfied: true, previouslySatisfied: true))
        // Airplane mode off: the case the old code handled.
        XCTAssertTrue(WorkspaceListReloadPolicy.pathUpdateWarrantsReload(satisfied: true, previouslySatisfied: false))
        // Going offline is never a reason to fire a request.
        XCTAssertFalse(WorkspaceListReloadPolicy.pathUpdateWarrantsReload(satisfied: false, previouslySatisfied: true))
        XCTAssertFalse(WorkspaceListReloadPolicy.pathUpdateWarrantsReload(satisfied: false, previouslySatisfied: nil))
    }

    func testReloadStillOnlyHappensWhileTheSheetShowsAnError() {
        XCTAssertTrue(WorkspaceListReloadPolicy.shouldReload(isLoading: false, workspaceCount: 0, errorMessage: "offline"))
        XCTAssertFalse(WorkspaceListReloadPolicy.shouldReload(isLoading: true, workspaceCount: 0, errorMessage: "offline"))
        XCTAssertFalse(WorkspaceListReloadPolicy.shouldReload(isLoading: false, workspaceCount: 2, errorMessage: nil))
        XCTAssertFalse(WorkspaceListReloadPolicy.shouldReload(isLoading: false, workspaceCount: 0, errorMessage: nil))
    }

    // MARK: - Terminal: the reconnect budget outlives a handoff

    func testReconnectBudgetSpansAHandoffNotJustAHiccup() {
        let attempts = WebSocketTerminalView.maxReconnectAttempts
        XCTAssertGreaterThanOrEqual(attempts, 6)
        let total = (1...attempts).map(WebSocketTerminalView.reconnectDelay(attempt:)).reduce(0, +)
        XCTAssertGreaterThanOrEqual(total, 30, "a Wi-Fi → cellular handoff with Tailscale takes well over the old 7 s")
        XCTAssertLessThanOrEqual(total, 60, "but the user must not stare at a dead terminal for a minute")
    }

    func testDelaysDoubleAndThenCap() {
        XCTAssertEqual(WebSocketTerminalView.reconnectDelay(attempt: 1), 1)
        XCTAssertEqual(WebSocketTerminalView.reconnectDelay(attempt: 2), 2)
        XCTAssertEqual(WebSocketTerminalView.reconnectDelay(attempt: 3), 4)
        XCTAssertEqual(WebSocketTerminalView.reconnectDelay(attempt: 4), WebSocketTerminalView.maxReconnectDelay)
        XCTAssertEqual(WebSocketTerminalView.reconnectDelay(attempt: 40), WebSocketTerminalView.maxReconnectDelay)
        XCTAssertEqual(WebSocketTerminalView.reconnectDelay(attempt: 0), 1, "defensive: never a zero or negative delay")
    }

    func testAFailedNonceRefreshIsOneAttemptNotTheEnd() {
        // The refresh is an HTTP call to the Mac the socket just lost; during
        // a handoff it fails for the same reason and must be retried.
        for attempt in 1..<WebSocketTerminalView.maxReconnectAttempts {
            XCTAssertFalse(WebSocketTerminalView.shouldGiveUpAfterRefreshFailure(attempt: attempt), "attempt \(attempt)")
        }
        XCTAssertTrue(WebSocketTerminalView.shouldGiveUpAfterRefreshFailure(attempt: WebSocketTerminalView.maxReconnectAttempts))
    }
}
