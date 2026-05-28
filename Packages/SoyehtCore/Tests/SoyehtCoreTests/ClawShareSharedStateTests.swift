import Foundation
import XCTest

@testable import SoyehtCore

/// Round-trip tests for the App-Group-backed shared state. The same
/// `FileSystemClawShareSharedStore` runs in the host app and inside
/// the `SoyehtClawShareTunnelProvider` extension; a regression in
/// the on-disk shape breaks both sides at once.
final class ClawShareSharedStateTests: XCTestCase {
    private func makeStore() throws -> (FileSystemClawShareSharedStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claw-share-shared-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (FileSystemClawShareSharedStore(directory: dir), dir)
    }

    func testCredentialRoundTrip() throws {
        let (store, _) = try makeStore()
        let record = ClawShareSharedCredential(
            credentialCBOR: Data([0x01, 0x02, 0x03]),
            issuedAtUnix: 1_800_000_000,
            expiresAtUnix: 1_800_086_400,
            clawId: "claw_test"
        )
        try store.saveCredential(record)
        let loaded = try store.loadCredential()
        XCTAssertEqual(loaded, record)
        try store.clearCredential()
        XCTAssertNil(try store.loadCredential())
    }

    func testSessionRequestRoundTrip() throws {
        let (store, _) = try makeStore()
        let request = ClawShareSharedSessionRequest(
            slotIdHex: "abcdef0123456789abcdef0123456789",
            requestedAtUnix: 1_800_000_500,
            attempt: 1
        )
        try store.saveSessionRequest(request)
        XCTAssertEqual(try store.loadSessionRequest(), request)
        try store.clearSessionRequest()
        XCTAssertNil(try store.loadSessionRequest())
    }

    func testStatusEnumWireRoundTrip() throws {
        let (store, _) = try makeStore()
        let cases: [ClawShareSessionStatus] = [
            .idle,
            .credentialReady,
            .dialing,
            .awaitingFirstPacket,
            .connected(sinceUnix: 1_800_000_999),
            .streamReady(sinceUnix: 1_800_001_000),
            .stopped(reason: "user"),
            .failed(reason: "handshake"),
        ]
        for state in cases {
            let wire = ClawShareSharedSessionStatus(state, updatedAtUnix: 0)
            try store.saveStatus(wire)
            let loaded = try store.loadStatus()
            XCTAssertEqual(loaded, wire)
            XCTAssertEqual(loaded?.decoded, state, "decoded must round-trip exactly")
        }
    }

    /// Apple-grade contract: if the persisted status is anything
    /// other than `.streamReady`, the host UI is forbidden from
    /// rendering the "open" affordance — INCLUDING `.connected`
    /// (tunnel-ready ≠ openable). Reading + decoding back MUST preserve
    /// the `isOpenable` property exactly.
    func testIsOpenablePreservedAcrossDiskRoundTrip() throws {
        let (store, _) = try makeStore()
        let nonOpen: [ClawShareSessionStatus] = [
            .idle, .credentialReady, .dialing,
            .awaitingFirstPacket,
            .connected(sinceUnix: 1),
            .stopped(reason: "user"), .failed(reason: "transport"),
        ]
        for state in nonOpen {
            try store.saveStatus(ClawShareSharedSessionStatus(state, updatedAtUnix: 1))
            let decoded = try store.loadStatus()?.decoded
            XCTAssertEqual(decoded?.isOpenable, false, "non-packet-verified disk state must NOT be openable: \(state)")
        }
        try store.saveStatus(ClawShareSharedSessionStatus(.streamReady(sinceUnix: 1), updatedAtUnix: 2))
        XCTAssertEqual(try store.loadStatus()?.decoded?.isOpenable, true)
    }
}
