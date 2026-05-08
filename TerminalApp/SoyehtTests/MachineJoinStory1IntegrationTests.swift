import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// **T031** — Story 1 (Bonjour-shortcut) end-to-end integration test.
///
/// Wires the same primitives the production runtime composes
/// (`OwnerEventsLongPoll` → `JoinRequestQueue` →
/// `JoinRequestConfirmationViewModel` → `OwnerApprovalClient` →
/// `HouseholdGossipConsumer` → `HouseholdMembershipStore`) and runs the
/// full join-request → approval → gossip-applied-member loop with stubbed
/// transports so the assertion surface covers:
///
/// - **SC-001**: long-poll-arrival → membership-applied within 15 s wall-clock.
/// - **SC-009 + FR-016**: outbound traffic during the run is exclusively
///   long-poll, gossip WS, and PoP-signed RPCs (`approve`, `snapshot`) — zero
///   polling requests to any household-member endpoint.
@MainActor
final class MachineJoinStory1IntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let baseURL = URL(string: "https://household.example")!

    /// Story 1 happy path: a Bonjour-shortcut-origin owner-event arrives
    /// via the foreground long-poll, the operator confirms biometrically,
    /// the approval POST succeeds, the gossip consumer applies the
    /// resulting `machine_added` event, and `HouseholdMembershipStore`
    /// reflects the new candidate — all inside the SC-001 budget and
    /// without any traffic outside the documented Phase 3 surface.
    func testBonjourOriginJoinReachesGossipAppliedMembershipUnder15Seconds() async throws {
        let runStart = Date()

        // Identities: household root, founder Mac (issuer of owner-events
        // and gossip events), candidate Mac (the unjoined machine), and
        // the iPhone owner identity that signs the approval.
        let householdKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)

        let founderKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let founderPublicKey = founderKey.publicKey.compressedRepresentation
        let founderMachineId = try HouseholdIdentifiers.identifier(
            for: founderPublicKey,
            kind: .machine
        )

        let candidateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let candidatePublicKey = candidateKey.publicKey.compressedRepresentation

        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let ownerPersonId = try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey)

        // Membership store seeded with the founder Mac so the
        // owner-events / gossip event verifiers can resolve the issuer.
        let founderCertCBOR = try MachineJoinTestFixtures.signedMachineCert(
            householdPrivateKey: householdKey,
            machinePublicKey: founderPublicKey,
            householdId: householdId,
            hostname: "founder.local",
            joinedAt: now.addingTimeInterval(-3600)
        )
        let founderCert = try MachineCert(cbor: founderCertCBOR)
        let membershipStore = HouseholdMembershipStore(
            initial: [HouseholdMember(from: founderCert)]
        )
        XCTAssertEqual(founderCert.machineId, founderMachineId)

        let crlStore = try CRLStore(
            storage: TestInMemoryHouseholdStorage(),
            account: UUID().uuidString
        )
        let queue = JoinRequestQueue()

        // Build the Bonjour-origin join request the founder Mac forwards.
        let envelope = try MachineJoinTestFixtures.bonjourJoinRequestEnvelope(
            candidatePrivateKey: candidateKey,
            nonce: Data(repeating: 0xAB, count: 32),
            ttlUnix: UInt64(now.timeIntervalSince1970) + 240,
            householdId: householdId,
            receivedAt: now
        )
        let fingerprint = try OperatorFingerprint
            .derive(machinePublicKey: candidatePublicKey, wordlist: BIP39Wordlist())
            .words
            .joined(separator: " ")
        let joinRequestPayload: [String: HouseholdCBORValue] = [
            "expiry": .unsigned(envelope.ttlUnix),
            "fingerprint": .text(fingerprint),
            "join_request_cbor": .bytes(MachineJoinTestFixtures.joinRequestCBOR(envelope: envelope)),
        ]
        let cursor: UInt64 = 41
        let ownerEvent = try MachineJoinTestFixtures.ownerEventCBOR(
            cursor: cursor,
            type: "join-request",
            payload: joinRequestPayload,
            timestamp: now,
            issuerMachineId: founderMachineId,
            issuerKey: founderKey
        )
        let pollResponse = MachineJoinTestFixtures.ownerEventsResponse(
            events: [ownerEvent],
            nextCursor: cursor
        )

        // Approval ACK the founder Mac would emit after the iPhone POSTs
        // the operator authorization. Hash content is opaque to the
        // iPhone — only the canonical wire shape matters here.
        let approvalAckBody = HouseholdCBOR.encode(.map([
            "machine_cert_hash": .bytes(Data(repeating: 0xCD, count: 32)),
            "v": .unsigned(1),
        ]))

        let recorder = TrafficRecorder()

        // Single transport closure routes both the long-poll GET and the
        // approval POST through the recorder; status + body is selected
        // off the URL path so the test reads top-down.
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            await recorder.record(request)
            let path = request.url?.path ?? ""
            let status: Int
            let body: Data
            if path == "/api/v1/household/owner-events" {
                status = 200
                body = pollResponse
            } else if path.hasPrefix("/api/v1/household/owner-events/")
                && path.hasSuffix("/approve") {
                status = 200
                body = approvalAckBody
            } else {
                XCTFail("Unexpected outbound path: \(path)")
                status = 500
                body = Data()
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/cbor"]
            )!
            return (body, response)
        }

        // Long-poll + verifier wired against the seeded membership store.
        let longPoll = OwnerEventsLongPoll(
            baseURL: baseURL,
            householdId: householdId,
            queue: queue,
            wordlist: try BIP39Wordlist(),
            authorizationProvider: { _, _, _ in "Soyeht-PoP test-pop-token" },
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
            transport: transport,
            nowProvider: { self.now }
        )

        let pollResult = try await longPoll.pollOnce(now: now)
        XCTAssertEqual(pollResult.cursor, cursor)
        XCTAssertEqual(pollResult.enqueuedJoinRequests.count, 1)
        XCTAssertEqual(pollResult.enqueuedJoinRequests.first?.idempotencyKey, envelope.idempotencyKey)
        let pendingAfterPoll = await queue.pendingRequests(now: now)
        XCTAssertEqual(pendingAfterPoll.map(\.envelope.idempotencyKey), [envelope.idempotencyKey])

        // ViewModel + production OperatorAuthorizationSigner against an
        // in-memory P256 key. The approval POST goes through the same
        // recorder so the path appears in the traffic-shape assertion.
        let ownerIdentity = try InMemoryOwnerIdentityKey(
            publicKey: ownerPublicKey,
            keyReference: "test-owner",
            signer: { payload in
                try ownerKey.signature(for: payload).rawRepresentation
            }
        )
        XCTAssertEqual(ownerIdentity.personId, ownerPersonId)

        let approvalClient = OwnerApprovalClient(
            baseURL: baseURL,
            authorizationProvider: { _, _, _ in "Soyeht-PoP test-pop-token" },
            transport: transport
        )
        let viewModel = try JoinRequestConfirmationViewModel(
            envelope: envelope,
            cursor: cursor,
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
        let queueStillContainsAfterConfirm = await queue.contains(idempotencyKey: envelope.idempotencyKey)
        XCTAssertFalse(queueStillContainsAfterConfirm)

        // Build the matching `machine_added` gossip event signed by the
        // founder Mac, with the candidate's CBOR cert as payload, and
        // run it through the consumer.
        let candidateCertCBOR = try MachineJoinTestFixtures.signedMachineCert(
            householdPrivateKey: householdKey,
            machinePublicKey: candidatePublicKey,
            householdId: householdId,
            hostname: envelope.rawHostname,
            platform: envelope.rawPlatform,
            joinedAt: now
        )
        let candidateCert = try MachineCert(cbor: candidateCertCBOR)
        let gossipFrameBytes = try MachineJoinTestFixtures.gossipEventFrame(
            eventId: Data(repeating: 0xE1, count: 32),
            cursor: cursor + 1,
            type: "machine_added",
            timestamp: now,
            issuerMachineId: founderMachineId,
            issuerKey: founderKey,
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

        let result = try await consumer.process(.data(gossipFrameBytes))
        if case .machineAdded(_, let appliedCursor, let member, _) = result {
            XCTAssertEqual(appliedCursor, cursor + 1)
            XCTAssertEqual(member.machineId, candidateCert.machineId)
        } else {
            XCTFail("Expected `machine_added` apply result, got \(result)")
        }
        let snapshot = await membershipStore.snapshot()
        XCTAssertTrue(snapshot.contains { $0.machineId == candidateCert.machineId })

        // SC-001: full path well under the 15 s budget. Stubbed transports
        // make this trivial in CI; the assertion is here so a regression
        // that adds a sleep / reconnect-loop into the happy path fails the
        // suite immediately.
        let elapsed = Date().timeIntervalSince(runStart)
        XCTAssertLessThan(elapsed, 15.0, "Story 1 e2e exceeded SC-001 budget")

        // SC-009 / FR-016 traffic-shape contract: the only outbound paths
        // recorded must be the long-poll GET and the per-cursor approval
        // POST. Anything else (e.g. a polling probe to a per-member
        // endpoint) is a contract violation.
        let captured = await recorder.currentPaths()
        XCTAssertEqual(captured.count, 2, "Unexpected request count: \(captured)")
        XCTAssertEqual(captured.first, "/api/v1/household/owner-events")
        XCTAssertEqual(captured.last, "/api/v1/household/owner-events/\(cursor)/approve")
        let disallowed = await recorder.assertAllPathsAllowed()
        XCTAssertTrue(disallowed.isEmpty, "Disallowed traffic surfaced: \(disallowed)")
    }
}
