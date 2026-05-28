import Foundation
import XCTest

@testable import SoyehtCore

/// End-to-end host ↔ extension shared-state round trip.
///
/// The host app and the `SoyehtClawShareTunnelProvider` extension are
/// SEPARATE processes that only meet through the App Group container.
/// These tests model that by using TWO independent
/// `FileSystemClawShareSharedStore` instances pointed at the SAME
/// injected container directory (the App Group container URL is not
/// reachable from a unit test, so we inject the directory but keep the
/// exact same store type and on-disk shape both sides use in
/// production).
///
/// The Apple-grade property under test: a failure or in-flight status
/// the extension writes can NEVER be read back by the host as an
/// "openable" session — only a real `.connected` round-trip can.
final class ClawShareHostExtensionRoundTripTests: XCTestCase {
    private func makeContainer() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claw-share-appgroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Host stages a credential + request; the extension (a distinct
    /// store over the same container) reads the exact same bytes.
    func testHostStagesCredentialExtensionReadsSameBytes() throws {
        let container = try makeContainer()
        let hostStore = FileSystemClawShareSharedStore(directory: container)
        let extensionStore = FileSystemClawShareSharedStore(directory: container)

        let credential = ClawShareSharedCredential(
            credentialCBOR: Data([0xCA, 0xFE, 0xBA, 0xBE]),
            issuedAtUnix: 1_800_000_000,
            expiresAtUnix: 1_800_086_400,
            clawId: "claw_round_trip"
        )
        try hostStore.saveCredential(credential)
        try hostStore.saveSessionRequest(
            ClawShareSharedSessionRequest(slotIdHex: "00ff", requestedAtUnix: 1_800_000_001, attempt: 1)
        )

        XCTAssertEqual(try extensionStore.loadCredential(), credential)
        XCTAssertEqual(try extensionStore.loadSessionRequest()?.slotIdHex, "00ff")
    }

    /// The extension publishes a typed failure (the real flow when the
    /// `TunnelPlatformAdapter` FFI seam is missing); the host reads it
    /// back and the gate forbids any open affordance — no zombie
    /// "connected" state.
    func testExtensionFailureIsNeverOpenableOnHost() throws {
        let container = try makeContainer()
        let extensionStore = FileSystemClawShareSharedStore(directory: container)
        let hostStore = FileSystemClawShareSharedStore(directory: container)

        // Mirror exactly what SoyehtClawShareTunnelProvider persists on
        // a typed data-plane error.
        extensionStore.publishFromExtension(.failed(reason: "data-plane-not-installed"))

        let readBack = try hostStore.loadStatus()?.decoded
        XCTAssertEqual(readBack, .failed(reason: "data-plane-not-installed"))
        XCTAssertEqual(readBack?.isOpenable, false, "a failed status must never be openable")
    }

    /// Only `.targetVerified` (a real packet RTT) flows through to an
    /// openable host state. Crucially, `.connected` (health/tunnel-ready)
    /// does NOT — health alone is not permission to open the claw.
    func testOnlyPacketVerifiedRoundTripIsOpenableOnHost() throws {
        let container = try makeContainer()
        let extensionStore = FileSystemClawShareSharedStore(directory: container)
        let hostStore = FileSystemClawShareSharedStore(directory: container)

        // In-flight + tunnel-ready states — NONE openable, incl .connected.
        for state: ClawShareSessionStatus in [
            .credentialReady, .dialing, .awaitingFirstPacket,
            .connected(sinceUnix: 1_800_000_400),
        ] {
            extensionStore.publishFromExtension(state)
            XCTAssertEqual(try hostStore.loadStatus()?.decoded?.isOpenable, false, "\(state) must not be openable")
        }
        // Only a real packet round-trip unlocks open.
        extensionStore.publishFromExtension(.targetVerified(sinceUnix: 1_800_000_500))
        XCTAssertEqual(try hostStore.loadStatus()?.decoded?.isOpenable, true)
    }

    /// The host stages the engine endpoint; the extension (a fresh
    /// store over the same container) reads the exact same host:port.
    func testEndpointRoundTrip() throws {
        let container = try makeContainer()
        let hostStore = FileSystemClawShareSharedStore(directory: container)
        let extensionStore = FileSystemClawShareSharedStore(directory: container)

        try hostStore.saveEndpoint(ClawShareSharedEndpoint(host: "100.64.0.7", port: 7423))
        XCTAssertEqual(
            try extensionStore.loadEndpoint(),
            ClawShareSharedEndpoint(host: "100.64.0.7", port: 7423)
        )
    }

    /// App relaunch: the extension observed `.targetVerified`; the host
    /// process restarts (modelled by a brand-new store instance over the
    /// same container) and must rehydrate the SAME openable state — no
    /// loss, no downgrade, no zombie.
    func testRelaunchRehydratesPacketVerifiedState() throws {
        let container = try makeContainer()
        FileSystemClawShareSharedStore(directory: container)
            .publishFromExtension(.targetVerified(sinceUnix: 1_800_000_500))

        // Fresh store == fresh process after relaunch.
        let afterRelaunch = FileSystemClawShareSharedStore(directory: container)
        let status = try afterRelaunch.loadStatus()?.decoded
        XCTAssertEqual(status, .targetVerified(sinceUnix: 1_800_000_500))
        XCTAssertEqual(status?.isOpenable, true, "a packet-verified session must stay openable across relaunch")
    }

    /// App relaunch while only tunnel-ready (health done, no packet RTT):
    /// the host rehydrates `.connected` but the gate stays CLOSED — the
    /// UI must re-verify the packet path, not assume open.
    func testRelaunchWithOnlyConnectedIsNotOpenable() throws {
        let container = try makeContainer()
        FileSystemClawShareSharedStore(directory: container)
            .publishFromExtension(.connected(sinceUnix: 1_800_000_500))

        let afterRelaunch = FileSystemClawShareSharedStore(directory: container)
        let status = try afterRelaunch.loadStatus()?.decoded
        XCTAssertEqual(status, .connected(sinceUnix: 1_800_000_500))
        XCTAssertEqual(status?.isOpenable, false, "tunnel-ready alone must not be openable after relaunch")
        XCTAssertEqual(status?.isTunnelReady, true)
    }

    /// App relaunch after a failure: the host rehydrates a recoverable
    /// `.failed` state — NOT openable, and not a crash/blank. The UI can
    /// offer a fresh attempt without surfacing a technical error.
    func testRelaunchRehydratesFailedStateAsRecoverable() throws {
        let container = try makeContainer()
        FileSystemClawShareSharedStore(directory: container)
            .publishFromExtension(.failed(reason: "handshake-failed"))

        let afterRelaunch = FileSystemClawShareSharedStore(directory: container)
        let status = try afterRelaunch.loadStatus()?.decoded
        XCTAssertEqual(status, .failed(reason: "handshake-failed"))
        XCTAssertEqual(status?.isOpenable, false, "a failed session must never be openable")
    }
}

private extension ClawShareSharedStore {
    /// Convenience that writes a status exactly the way the extension
    /// does (wire shape + timestamp), so the test exercises the real
    /// on-disk contract rather than a bespoke encoding.
    func publishFromExtension(_ status: ClawShareSessionStatus) {
        try? saveStatus(ClawShareSharedSessionStatus(status, updatedAtUnix: 0))
    }
}
