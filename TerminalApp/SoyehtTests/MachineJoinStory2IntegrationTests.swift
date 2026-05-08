import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// **T039** — Story 2 (remote QR over Tailscale) end-to-end integration.
///
/// Scans a synthetic `pair-machine` URI, stages the resulting
/// `JoinRequestEnvelope` via the join-request HTTP RPC, the operator
/// confirms biometrically, the approval POST succeeds, and the gossip
/// consumer applies the matching `machine_added` event so
/// `HouseholdMembershipStore` reflects the new candidate. Asserts:
///
/// - **SC-002**: 25 s spec budget. Tightened to 1 s here for the same
///   reason Story 1's budget is tightened — under deterministic stubs
///   the path is sub-100 ms, and SC-002 itself is verified end-to-end
///   by the T058 / T059 hardware walkthroughs.
/// - **SC-009**: every captured outbound URL belongs to the documented
///   Phase 3 surface (`join-request`, `owner-events/.../approve`); zero
///   polling probes to per-member endpoints.
/// - **FR-029 anti-phishing**: parsing goes through `QRScannerDispatcher`
///   so a tampered URL would be rejected before any network I/O — the
///   Story 2 fixture builds a properly-signed URL and the dispatcher
///   accepts it.
/// - The verifiable APNS-empty-payload assertion lives in
///   `APNSPayloadInvariantTests` (T044a) per spec.md task notes; this
///   integration test does not re-assert the canonical `aps` body.
///
/// **Out of scope**: the `confirmingRequest` snapshot lock + lifecycle
/// `phaseObserver` ordering belong to `HouseholdMachineJoinRuntime` and
/// are exercised in `HouseholdMachineJoinRuntimeTests`. The staging
/// envelope rebuild here goes through the production
/// `JoinRequestEnvelope.withTTLUnix` helper so any future change to that
/// transition (e.g. `idempotencyKey` rederivation) propagates here for
/// free.
@MainActor
final class MachineJoinStory2IntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let baseURL = URL(string: "https://household.example")!

    func testQRScannedJoinReachesGossipAppliedMembershipUnder25Seconds() async throws {
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

        let candidateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x44, count: 32))
        let candidatePublicKey = candidateKey.publicKey.compressedRepresentation

        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x55, count: 32))
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation

        // Founder seeded so the gossip event verifier resolves the issuer.
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

        // Build the signed pair-machine URL the operator scans on the
        // remote candidate.
        let qrTTL = UInt64(now.timeIntervalSince1970) + 240
        let pairMachineURL = try MachineJoinTestFixtures.pairMachineURL(
            candidatePrivateKey: candidateKey,
            nonce: Data(repeating: 0xFE, count: 32),
            hostname: "studio.local",
            platform: .macos,
            transport: .tailscale,
            address: "studio.tailnet:8443",
            expiry: qrTTL
        )

        // Step 1: scanner dispatcher parses the URL and emits the
        // envelope. FR-029 challenge verification runs inside the
        // parser; a tampered URL would surface as
        // `MachineJoinError.qrInvalid(.signatureInvalid)` and fail the
        // test before any network call.
        let dispatchResult = QRScannerDispatcher.result(
            for: pairMachineURL,
            activeHouseholdId: householdId,
            now: now
        )
        guard case .success(.householdPairMachine(let envelope)) = dispatchResult else {
            XCTFail("Expected pair-machine result, got \(dispatchResult)")
            return
        }
        XCTAssertEqual(envelope.transportOrigin, .qrTailscale)
        XCTAssertEqual(envelope.householdId, householdId)
        XCTAssertEqual(envelope.machinePublicKey, candidatePublicKey)

        // Staging server reply: minimal CBOR-canonical
        // `JoinRequestAccepted` body. `expiry == qrTTL` is the only
        // legal value here — the staging client caps any
        // server-extended TTL to the QR's hard ceiling, so reusing the
        // QR TTL keeps the test focused on the staging round-trip.
        let acceptedCursor: UInt64 = 99
        let acceptedBody = HouseholdCBOR.encode(.map([
            "expiry": .unsigned(qrTTL),
            "owner_event_cursor": .unsigned(acceptedCursor),
            "v": .unsigned(1),
        ]))
        let approvalAck = HouseholdCBOR.encode(.map([
            "machine_cert_hash": .bytes(Data(repeating: 0xAB, count: 32)),
            "v": .unsigned(1),
        ]))

        let recorder = TrafficRecorder()
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            await recorder.record(request)
            let path = request.url?.path ?? ""
            let status: Int
            let body: Data
            if path == "/api/v1/household/join-request" {
                status = 200
                body = acceptedBody
            } else if path.hasPrefix("/api/v1/household/owner-events/")
                && path.hasSuffix("/approve") {
                status = 200
                body = approvalAck
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

        // Step 2: stage the envelope. This mirrors the production runtime's
        // `stageScannedMachineJoin` shape minus the Secure Enclave key
        // load (we wire the PoP authorization closure directly).
        let stagingClient = JoinRequestStagingClient(
            baseURL: baseURL,
            authorizationProvider: { _, _, _ in "Soyeht-PoP test-pop-token" },
            transport: transport
        )
        let accepted = try await stagingClient.submit(envelope)
        XCTAssertEqual(accepted.ownerEventCursor, acceptedCursor)
        XCTAssertEqual(accepted.expiry, qrTTL)
        let stagedTTL = try HouseholdMachineJoinRuntime.cappedStagedTTL(
            originalTTLUnix: envelope.ttlUnix,
            acceptedExpiry: accepted.expiry,
            now: now
        )
        // The runtime rebuilds the envelope with the capped TTL via
        // `JoinRequestEnvelope.withTTLUnix`. We call the production
        // helper directly so the queue entry the VM claims is byte-equal
        // to what `HouseholdMachineJoinRuntime.stageScannedMachineJoin`
        // produces — any future change to the helper (e.g. recomputing a
        // derived field) propagates into this test for free.
        let stagedEnvelope = envelope.withTTLUnix(stagedTTL)
        let inserted = await queue.enqueue(stagedEnvelope, cursor: accepted.ownerEventCursor)
        XCTAssertTrue(inserted)
        let pending = await queue.pendingRequests(now: now)
        XCTAssertEqual(pending.map(\.envelope.idempotencyKey), [stagedEnvelope.idempotencyKey])

        // Step 3: operator confirms. Identical signing path to Story 1
        // — Story 2's only divergence is how the envelope arrives.
        let ownerIdentity = try InMemoryOwnerIdentityKey(
            publicKey: ownerPublicKey,
            keyReference: "story2-owner",
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
            envelope: stagedEnvelope,
            cursor: accepted.ownerEventCursor,
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

        // Step 4: gossip event for the candidate, signed by founder Mac
        // (the same machine that processed the staging POST in
        // production).
        let candidateCertCBOR = try MachineJoinTestFixtures.signedMachineCert(
            householdPrivateKey: householdKey,
            machinePublicKey: candidatePublicKey,
            householdId: householdId,
            hostname: stagedEnvelope.rawHostname,
            platform: stagedEnvelope.rawPlatform,
            joinedAt: now
        )
        let candidateCert = try MachineCert(cbor: candidateCertCBOR)
        let gossipFrame = try MachineJoinTestFixtures.gossipEventFrame(
            eventId: Data(repeating: 0xE9, count: 32),
            cursor: acceptedCursor + 1,
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
        let result = try await consumer.process(.data(gossipFrame))
        if case .machineAdded(_, let appliedCursor, let member, _) = result {
            XCTAssertEqual(appliedCursor, acceptedCursor + 1)
            XCTAssertEqual(member.machineId, candidateCert.machineId)
        } else {
            XCTFail("Expected `machine_added` apply result, got \(result)")
        }
        let snapshot = await membershipStore.snapshot()
        XCTAssertTrue(snapshot.contains { $0.machineId == candidateCert.machineId })

        // Cursor persistence — gossip consumer must commit the applied
        // cursor for the post-approval `machine_added`.
        XCTAssertEqual(
            cursorStore.loadCursor(for: householdId),
            acceptedCursor + 1,
            "Gossip consumer did not persist the applied cursor"
        )

        // SC-002 budget assertion: tightened from the 25 s spec budget
        // to 1 s. SC-002 itself is verified end-to-end by the
        // T058 / T059 hardware walkthroughs.
        let elapsed = Date().timeIntervalSince(runStart)
        XCTAssertLessThan(elapsed, 1.0, "Story 2 e2e exceeded the tightened 1 s test budget; SC-002 spec budget is 25 s but stubs should run in <100 ms")

        // SC-009: traffic shape — staging POST + approval POST only.
        let capturedRequests = await recorder.currentRequests()
        XCTAssertEqual(capturedRequests.count, 2, "Unexpected request count: \(capturedRequests.map { $0.url?.path ?? "?" })")
        XCTAssertEqual(capturedRequests.first?.url?.path, "/api/v1/household/join-request")
        XCTAssertEqual(capturedRequests.last?.url?.path, "/api/v1/household/owner-events/\(acceptedCursor)/approve")
        let disallowed = await recorder.assertAllPathsAllowed()
        XCTAssertTrue(disallowed.isEmpty, "Disallowed traffic surfaced: \(disallowed)")
    }
}
