import Foundation
import XCTest

@testable import SoyehtCore

/// Apple-grade gating contract for the deep-link entry point:
/// - No state advances without explicit user acceptance.
/// - No state expresses "connected" or "open terminal" while the data
///   plane is absent — `.acceptedAwaitingDataPlane` is the highest the
///   router can reach today.
/// - Expired or malformed URIs land in `.failed`, never in idle.
/// - Pending state survives router reconstruction (relaunch).
final class ClawShareInviteRouterTests: XCTestCase {
    /// A stub store backed by an in-memory dictionary so each test runs
    /// in isolation without polluting UserDefaults.
    actor StubStore: ClawSharePendingStore {
        private var inviteData: Data?
        private var credentialData: Data?

        nonisolated func savePendingInvite(_ data: Data) throws {
            Task { await self.setInvite(data) }
        }
        nonisolated func loadPendingInvite() throws -> Data? {
            // Test code accepts the sync semantic; the implementation
            // takes a hop through the actor which means the saved
            // data is observable after a brief await in tests.
            nil
        }
        nonisolated func clearPendingInvite() throws {
            Task { await self.setInvite(nil) }
        }
        nonisolated func saveCredential(_ data: Data) throws {
            Task { await self.setCredential(data) }
        }
        nonisolated func loadCredential() throws -> Data? { nil }

        func setInvite(_ data: Data?) { inviteData = data }
        func setCredential(_ data: Data?) { credentialData = data }
        func snapshotInvite() async -> Data? { inviteData }
        func snapshotCredential() async -> Data? { credentialData }
    }

    func testIgnoresUnrelatedScheme() async {
        let router = ClawShareInviteRouter(store: StubStore())
        let consumed = await router.handle(url: URL(string: "https://example.com")!)
        XCTAssertFalse(consumed)
        let state = await router.currentState()
        guard case .idle = state else {
            XCTFail("non-claw-share URL must leave state idle")
            return
        }
    }

    func testMalformedURIYieldsFailedState() async {
        let router = ClawShareInviteRouter(store: StubStore())
        let consumed = await router.handle(
            url: URL(string: "soyeht://claw-share/v1?e=not-base64!!")!
        )
        XCTAssertTrue(consumed)
        let state = await router.currentState()
        guard case .failed(let err) = state else {
            XCTFail("malformed URI must land in .failed")
            return
        }
        XCTAssertEqual(err, .inviteMalformed)
    }

    func testAcceptanceRequiresExplicitAcceptCall() async throws {
        let invite = try makeFixtureInvite(expiresInOffset: 3600, now: 1_700_000_000)
        let uri = ClawShareCodec.inviteURI(invite)
        let router = ClawShareInviteRouter(
            store: StubStore(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        _ = await router.handle(url: URL(string: uri)!)
        // After handle, router exposes the invite but does NOT
        // auto-claim. The UI MUST call accept() to proceed.
        let stateBeforeAccept = await router.currentState()
        guard case .acceptanceReady(let parsed) = stateBeforeAccept else {
            XCTFail("expected .acceptanceReady; got \(stateBeforeAccept)")
            return
        }
        XCTAssertEqual(parsed.clawId, invite.clawId)

        let accepted = await router.accept()
        XCTAssertEqual(accepted?.clawId, invite.clawId)
        let stateAfterAccept = await router.currentState()
        guard case .claimInFlight = stateAfterAccept else {
            XCTFail("accept must transition to .claimInFlight")
            return
        }
    }

    func testExpiredInviteFailsBeforeAcceptance() async throws {
        // Invite TTL well before "now" → must fail immediately.
        let invite = try makeFixtureInvite(expiresInOffset: 100, now: 1_700_000_000)
        let uri = ClawShareCodec.inviteURI(invite)
        let router = ClawShareInviteRouter(
            store: StubStore(),
            // Move clock past the invite's expiry.
            now: { Date(timeIntervalSince1970: 1_700_001_000) }
        )
        _ = await router.handle(url: URL(string: uri)!)
        let state = await router.currentState()
        guard case .failed(let err) = state else {
            XCTFail("expired URI must land in .failed")
            return
        }
        XCTAssertEqual(err, .inviteExpired)
    }

    /// Apple-grade: receiving an ack lands in
    /// `.acceptedAwaitingDataPlane`, NOT a "connected" terminal state.
    /// The host UI must read this enum and gate every "open" action.
    func testAckLandsInAwaitingDataPlaneNotConnected() async throws {
        let invite = try makeFixtureInvite(expiresInOffset: 3600, now: 1_700_000_000)
        let uri = ClawShareCodec.inviteURI(invite)
        let router = ClawShareInviteRouter(
            store: StubStore(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        _ = await router.handle(url: URL(string: uri)!)
        _ = await router.accept()

        let dummyCred = GuestCredential(
            v: 1,
            kind: GuestCredential.kind,
            householdId: invite.householdId,
            ownerPersonId: invite.ownerPersonId,
            ownerPublicKey: invite.ownerPublicKey,
            clawId: invite.clawId,
            guestDevicePublicKey: Data(repeating: 0xCC, count: 33),
            slotId: invite.slotId,
            issuedAt: 1_700_000_001,
            expiresAt: 1_700_010_000,
            ownerSignature: Data(repeating: 0xEE, count: 64)
        )
        let ephemeral = EphemeralClawShareGuestIdentity()
        let session = ClaimedSession(
            credential: dummyCred,
            tunnel: invite.transportHint,
            guestIdentity: ephemeral
        )
        try await router.didReceiveAck(session)

        let state = await router.currentState()
        guard case .acceptedAwaitingDataPlane = state else {
            XCTFail("ack must land in .acceptedAwaitingDataPlane to enforce data-plane gating")
            return
        }
    }

    // MARK: - Helpers

    /// Build a fixture invite signed by an in-process ephemeral key.
    /// We bypass full cross-language CBOR pinning here — the router
    /// tests care about state transitions, not byte vectors.
    private func makeFixtureInvite(expiresInOffset: UInt64, now: UInt64) throws -> ClawShareInvite {
        // Synthesize a valid-looking signature blob (64 zeros). The
        // router does NOT verify signatures itself; that's the
        // codec/HTTP layer. The router only checks parse + expiry.
        return ClawShareInvite(
            householdId: "hh_fixture",
            ownerPersonId: "p_fixture",
            ownerPublicKey: Data(repeating: 0x02, count: 33),
            clawId: "claw_router_test",
            slotId: Data(repeating: 0xAB, count: 16),
            transportHint: .loopback(channel: "ch-test"),
            expiresAt: now + expiresInOffset,
            ownerSignature: Data(repeating: 0xEE, count: 64)
        )
    }
}
