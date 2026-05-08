import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// **T044c** — elected-sender failover, iPhone-observable surface.
///
/// SC-016 requires that "founding Mac powered down → backup machine takes
/// APNS sender role within 1 s per theyos §13 election; Story 1 join still
/// completes in SC-001 budget". The sub-second leader-election timing is
/// owned by `theyos` (the household servers), and `tasks.md` lists this
/// task under the cross-repo gate **"blocked on theyos implementing the
/// leader-election protocol §13 with sub-second APNS-sender failover"**.
/// The full <1 s wall-clock assertion is therefore validated end-to-end
/// only by the real-hardware walkthrough T061.
///
/// What this test pins on the iPhone side is the property the household
/// switchover requires of the client: **the iPhone tolerates a sender
/// swap mid-flow without losing cursor, dropping events, or rejecting
/// subsequently-signed traffic**, and Story 1 still completes within the
/// SC-001 15 s budget after the switchover. Concretely:
///
/// 1. The first owner-events long-poll returns 204 — modelling the
///    founder Mac dying mid-poll before it could emit the join-request.
///    The poller must keep its cursor and re-poll cleanly. To make
///    cursor preservation observable (a 0 → 0 transition holds by
///    construction in the 204 branch), the poller is seeded with
///    `initialCursor: 50` so the assertion catches a regression that
///    would silently rewind on 204.
/// 2. The second long-poll returns the join-request event **signed by a
///    different (backup) household member** that the iPhone has in its
///    membership store. The owner-event verifier must resolve the new
///    issuer and accept the event without operator intervention.
/// 3. The corresponding `machine_added` gossip event is also emitted by
///    the backup Mac — the consumer must accept it under the same
///    membership lookup.
///
/// **Out of scope**: snapshot-lock + lifecycle phase boundaries belong
/// to `HouseholdMachineJoinRuntime` and live in
/// `HouseholdMachineJoinRuntimeTests`.
@MainActor
final class MachineJoinFailoverIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let baseURL = URL(string: "https://household.example")!

    func testIPhoneToleratesAPNSSenderSwitchoverDuringStory1() async throws {
        let runStart = Date()

        let householdKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)

        let founderKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let founderPublicKey = founderKey.publicKey.compressedRepresentation
        let founderMachineId = try HouseholdIdentifiers.identifier(
            for: founderPublicKey,
            kind: .machine
        )

        let backupKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x12, count: 32))
        let backupPublicKey = backupKey.publicKey.compressedRepresentation
        let backupMachineId = try HouseholdIdentifiers.identifier(
            for: backupPublicKey,
            kind: .machine
        )
        XCTAssertNotEqual(founderMachineId, backupMachineId)

        let candidateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x66, count: 32))
        let candidatePublicKey = candidateKey.publicKey.compressedRepresentation

        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x77, count: 32))
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation

        // Both the founder and the backup must be members before the
        // switchover so the iPhone can verify owner-events / gossip
        // signed by either. This mirrors a real household where the
        // backup Mac was joined earlier and is now eligible for
        // election when the founder drops.
        let founderCertCBOR = try MachineJoinTestFixtures.signedMachineCert(
            householdPrivateKey: householdKey,
            machinePublicKey: founderPublicKey,
            householdId: householdId,
            hostname: "founder.local",
            joinedAt: now.addingTimeInterval(-7200)
        )
        let backupCertCBOR = try MachineJoinTestFixtures.signedMachineCert(
            householdPrivateKey: householdKey,
            machinePublicKey: backupPublicKey,
            householdId: householdId,
            hostname: "backup.local",
            joinedAt: now.addingTimeInterval(-3600)
        )
        let founderCert = try MachineCert(cbor: founderCertCBOR)
        let backupCert = try MachineCert(cbor: backupCertCBOR)
        let membershipStore = HouseholdMembershipStore(
            initial: [
                HouseholdMember(from: founderCert),
                HouseholdMember(from: backupCert),
            ]
        )

        let crlStore = try CRLStore(
            storage: TestInMemoryHouseholdStorage(),
            account: UUID().uuidString
        )
        let queue = JoinRequestQueue()

        // Build the join-request envelope the **backup** Mac forwards
        // post-switchover (the founder went down before it could).
        let envelope = try MachineJoinTestFixtures.bonjourJoinRequestEnvelope(
            candidatePrivateKey: candidateKey,
            nonce: Data(repeating: 0xCD, count: 32),
            ttlUnix: UInt64(now.timeIntervalSince1970) + 240,
            householdId: householdId,
            receivedAt: now
        )
        let fingerprint = try OperatorFingerprint
            .derive(machinePublicKey: candidatePublicKey, wordlist: BIP39Wordlist())
            .words
            .joined(separator: " ")
        let joinRequestCursor: UInt64 = 88
        let backupSignedEvent = try MachineJoinTestFixtures.ownerEventCBOR(
            cursor: joinRequestCursor,
            type: "join-request",
            payload: [
                "expiry": .unsigned(envelope.ttlUnix),
                "fingerprint": .text(fingerprint),
                "join_request_cbor": .bytes(MachineJoinTestFixtures.joinRequestCBOR(envelope: envelope)),
            ],
            timestamp: now,
            issuerMachineId: backupMachineId,
            issuerKey: backupKey
        )
        let postSwitchoverResponse = MachineJoinTestFixtures.ownerEventsResponse(
            events: [backupSignedEvent],
            nextCursor: joinRequestCursor
        )
        let approvalAck = HouseholdCBOR.encode(.map([
            "machine_cert_hash": .bytes(Data(repeating: 0xAB, count: 32)),
            "v": .unsigned(1),
        ]))

        let recorder = TrafficRecorder()

        // Stateful transport: the first owner-events GET returns 204
        // (founder dying mid-poll, no events to emit); subsequent GETs
        // return the backup-signed event. The approval POST completes
        // normally.
        let pollCount = PollCounter()
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            await recorder.record(request)
            let path = request.url?.path ?? ""
            if path == "/api/v1/household/owner-events" {
                let attempt = await pollCount.incrementAndGet()
                let status: Int
                let body: Data
                let contentType: String?
                if attempt == 1 {
                    // Founder Mac powered down right before emitting
                    // the join-request — the long-poll times out
                    // empty.
                    status = 204
                    body = Data()
                    contentType = nil
                } else {
                    // Backup Mac has taken the APNS-sender role and is
                    // now the issuer. Cursor unchanged because the
                    // 204 didn't advance it.
                    status = 200
                    body = postSwitchoverResponse
                    contentType = "application/cbor"
                }
                var headers: [String: String] = [:]
                if let contentType { headers["Content-Type"] = contentType }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                return (body, response)
            }
            if path.hasPrefix("/api/v1/household/owner-events/")
                && path.hasSuffix("/approve") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/cbor"]
                )!
                return (approvalAck, response)
            }
            XCTFail("Unexpected outbound path: \(path)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), response)
        }

        // Seed an initial cursor so the 204 branch's "cursor preserved"
        // contract becomes non-trivially observable. With `initialCursor:
        // 0`, the 204 branch's `cursor: 0` return is a tautology — every
        // 204 always returns whatever cursor was already at — so the
        // cursor-preservation regression we care about (a poll that
        // silently rewinds on 204) wouldn't surface. Seeding at 50 makes
        // the firstPoll cursor assertion (still 50) load-bearing.
        let initialCursor: UInt64 = 50
        let longPoll = OwnerEventsLongPoll(
            baseURL: baseURL,
            householdId: householdId,
            queue: queue,
            wordlist: try BIP39Wordlist(),
            initialCursor: initialCursor,
            authorizationProvider: { _, _, _ in "Soyeht-PoP test-pop-token" },
            eventVerifier: { event in
                // The verifier resolves the issuer through the membership
                // store — both the founder (pre-switchover) and the
                // backup (post-switchover) are present, so a sender swap
                // is a valid issuer change, not a verification failure.
                guard let member = await membershipStore.member(for: event.issuerMachineId) else {
                    throw MachineJoinError.certValidationFailed(reason: .wrongIssuer)
                }
                let key = try P256.Signing.PublicKey(compressedRepresentation: member.machinePublicKey)
                let signature = try P256.Signing.ECDSASignature(rawRepresentation: event.signature)
                guard key.isValidSignature(signature, for: event.signingBytes) else {
                    throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
                }
            },
            transport: transport,
            nowProvider: { self.now }
        )

        // First poll: 204 (founder died, no event yet). Cursor must
        // not move — assertion catches a regression that rewinds on
        // 204 because we seeded `initialCursor: 50` above.
        let firstPoll = try await longPoll.pollOnce(now: now)
        XCTAssertTrue(firstPoll.timedOut)
        XCTAssertEqual(firstPoll.previousCursor, initialCursor)
        XCTAssertEqual(firstPoll.cursor, initialCursor)
        let cursorAfterFirstPoll = await longPoll.currentCursor()
        XCTAssertEqual(cursorAfterFirstPoll, initialCursor)
        XCTAssertEqual(firstPoll.enqueuedJoinRequests.count, 0)

        // Second poll: backup Mac is now the elected sender; the
        // event arrives and the iPhone accepts it under the (still
        // valid) backup-Mac signature.
        let secondPoll = try await longPoll.pollOnce(now: now)
        XCTAssertEqual(secondPoll.cursor, joinRequestCursor)
        XCTAssertEqual(secondPoll.enqueuedJoinRequests.count, 1)
        XCTAssertEqual(
            secondPoll.enqueuedJoinRequests.first?.idempotencyKey,
            envelope.idempotencyKey
        )

        // Operator confirm path is identical to Story 1; the only
        // failover-specific surface is the issuer of the
        // owner-events / gossip — verifying the rest of the path
        // still completes proves the switchover is invisible to the
        // operator.
        let ownerIdentity = try InMemoryOwnerIdentityKey(
            publicKey: ownerPublicKey,
            keyReference: "failover-owner",
            signer: { payload in
                try ownerKey.signature(for: payload).rawRepresentation
            }
        )
        let approvalClient = OwnerApprovalClient(
            baseURL: baseURL,
            authorizationProvider: { _, _, _ in "Soyeht-PoP test-pop-token" },
            transport: transport
        )
        let viewModel = try JoinRequestConfirmationViewModel(
            envelope: envelope,
            cursor: joinRequestCursor,
            queue: queue,
            wordlist: BIP39Wordlist(),
            nowProvider: { self.now },
            signAction: { claimed, claimedCursor in
                try OperatorAuthorizationSigner().sign(
                    envelope: claimed,
                    cursor: claimedCursor,
                    ownerIdentity: ownerIdentity,
                    localHouseholdId: householdId,
                    now: self.now
                )
            },
            submitAction: { _, authorization in
                _ = try await approvalClient.approve(authorization)
            }
        )

        await viewModel.confirm()
        XCTAssertEqual(viewModel.state, .succeeded)

        // Gossip `machine_added` for the candidate, also signed by the
        // **backup** Mac because the founder is still gone.
        let candidateCertCBOR = try MachineJoinTestFixtures.signedMachineCert(
            householdPrivateKey: householdKey,
            machinePublicKey: candidatePublicKey,
            householdId: householdId,
            hostname: envelope.rawHostname,
            platform: envelope.rawPlatform,
            joinedAt: now
        )
        let candidateCert = try MachineCert(cbor: candidateCertCBOR)
        let gossipFrame = try MachineJoinTestFixtures.gossipEventFrame(
            eventId: Data(repeating: 0xF7, count: 32),
            cursor: joinRequestCursor + 1,
            type: "machine_added",
            timestamp: now,
            issuerMachineId: backupMachineId,
            issuerKey: backupKey,
            payload: ["machine_cert": .bytes(candidateCertCBOR)]
        )
        let cursorStore = TestInMemoryGossipCursorStore()
        let consumer = HouseholdGossipConsumer(
            householdId: householdId,
            householdPublicKey: householdPublicKey,
            crlStore: crlStore,
            membershipStore: membershipStore,
            queue: queue,
            cursorStore: cursorStore,
            eventVerifier: { event in
                guard let member = await membershipStore.member(for: event.issuerMachineId) else {
                    throw MachineJoinError.certValidationFailed(reason: .wrongIssuer)
                }
                let key = try P256.Signing.PublicKey(compressedRepresentation: member.machinePublicKey)
                let signature = try P256.Signing.ECDSASignature(rawRepresentation: event.signature)
                guard key.isValidSignature(signature, for: event.signingBytes) else {
                    throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
                }
            },
            nowProvider: { self.now }
        )
        let result = try await consumer.process(.data(gossipFrame))
        if case .machineAdded(_, let appliedCursor, let member, _) = result {
            XCTAssertEqual(appliedCursor, joinRequestCursor + 1)
            XCTAssertEqual(member.machineId, candidateCert.machineId)
        } else {
            XCTFail("Expected `machine_added` apply result, got \(result)")
        }

        // Cursor persistence across the failover — the consumer must
        // commit even though the issuer changed mid-flow.
        XCTAssertEqual(
            cursorStore.loadCursor(for: householdId),
            joinRequestCursor + 1,
            "Gossip consumer did not persist the post-failover applied cursor"
        )

        // Story 1 budget still holds across the failover. Tightened to
        // 1 s for the same reason as Story 1 (deterministic stubs run
        // sub-100 ms; SC-016's <1 s timing is owned by theyos §13 and
        // validated end-to-end only by T061).
        let elapsed = Date().timeIntervalSince(runStart)
        XCTAssertLessThan(elapsed, 1.0, "Story 1 budget violated across failover; SC-001 spec budget is 15 s but stubs should run in <100 ms")

        // Traffic stays on the documented surface during the swap. The
        // long-poll URL must carry the `since=` cursor query so a
        // regression that drops cursor-on-the-wire is caught.
        let capturedRequests = await recorder.currentRequests()
        let longPolls = capturedRequests.filter { $0.url?.path == "/api/v1/household/owner-events" }
        XCTAssertEqual(longPolls.count, 2, "Expected exactly two long-poll requests across the switchover")
        for request in longPolls {
            let query = request.url?.query ?? ""
            XCTAssertTrue(
                query.contains("since="),
                "Long-poll URL missing `since=` cursor query: \(query)"
            )
        }
        XCTAssertTrue(
            capturedRequests.contains { request in
                guard let path = request.url?.path else { return false }
                return path.hasPrefix("/api/v1/household/owner-events/") && path.hasSuffix("/approve")
            }
        )
        let disallowed = await recorder.assertAllPathsAllowed()
        XCTAssertTrue(disallowed.isEmpty, "Disallowed traffic surfaced during failover: \(disallowed)")
    }
}

private actor PollCounter {
    private var value = 0

    func incrementAndGet() -> Int {
        value += 1
        return value
    }
}
