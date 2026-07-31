import Foundation
import Testing

@testable import SoyehtCore

struct RosterEvidenceClientTests {
    private final class SigningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var payload: Data? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ d: Data) { lock.lock(); stored = d; lock.unlock() }
    }

    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        let box: SigningBox
        func sign(_ payload: Data) throws -> Data {
            box.set(payload)
            return Data(repeating: 0x11, count: 64)
        }
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ r: URLRequest) { lock.lock(); stored = r; lock.unlock() }
    }

    private let nonce = Data(repeating: 0xAA, count: 32)

    private func makeClient(
        status: Int,
        responseBody: Data,
        contentType: String? = "application/cbor",
        box: RequestBox? = nil,
        signingBox: SigningBox = SigningBox()
    ) -> RosterEvidenceClient {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(box: signingBox),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return RosterEvidenceClient(
            baseURL: URL(string: "http://192.0.2.10:8101")!,
            popSigner: signer,
            perform: { req in
                box?.set(req)
                var headers: [String: String] = [:]
                if let contentType { headers["Content-Type"] = contentType }
                let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (responseBody, resp)
            }
        )
    }

    private func checkpointBytes(sequence: UInt64) -> Data {
        HouseholdCBOR.encode(.map(["checkpoint_sequence": .unsigned(sequence)]))
    }

    private func snapshotKind0() -> [String: HouseholdCBORValue] {
        ["v": .unsigned(1), "hh_id": .text("hh_test"), "state_kind": .unsigned(0), "floor_secs": .unsigned(100)]
    }

    private func snapshotKind1(sequence: UInt64) -> [String: HouseholdCBORValue] {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1), "hh_id": .text("hh_test"), "state_kind": .unsigned(1), "floor_secs": .unsigned(100),
            "genesis_checkpoint": .bytes(checkpointBytes(sequence: 1)),
            "accepted_checkpoint": .bytes(checkpointBytes(sequence: sequence)),
        ]
        if sequence > 1 { map["predecessor_checkpoint"] = .bytes(checkpointBytes(sequence: sequence - 1)) }
        return map
    }

    private func snapshotFork(kind: UInt64, sequence: UInt64) -> [String: HouseholdCBORValue] {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1), "hh_id": .text("hh_test"), "state_kind": .unsigned(kind), "floor_secs": .unsigned(100),
            "genesis_checkpoint": .bytes(checkpointBytes(sequence: 1)),
            "accepted_checkpoint": .bytes(checkpointBytes(sequence: sequence)),
            "conflicting_checkpoint": .bytes(checkpointBytes(sequence: sequence)),
        ]
        if sequence > 1 { map["predecessor_checkpoint"] = .bytes(checkpointBytes(sequence: sequence - 1)) }
        return map
    }

    private func availableBody(snapshot: [String: HouseholdCBORValue]) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("available"),
            "snapshot_body": .map(snapshot),
            "state_evidence_digest": .bytes(Data(repeating: 0x0A, count: 32)),
            "full_snapshot_digest": .bytes(Data(repeating: 0x0B, count: 32)),
            "signer_m_id": .text("m_aaa"),
            "signer_machine_cert": .bytes(Data([0x01, 0x02])),
            "signer_machine_cert_fingerprint": .bytes(Data(repeating: 0x0C, count: 32)),
            "client_nonce": .bytes(nonce),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
    }

    private func unavailableBody(_ outcome: String) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text(outcome),
            "signer_m_id": .text("m_aaa"),
            "signer_machine_cert": .bytes(Data([0x01, 0x02])),
            "signer_machine_cert_fingerprint": .bytes(Data(repeating: 0x0C, count: 32)),
            "client_nonce": .bytes(nonce),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
    }

    // MARK: - Shared snapshot decoder

    @Test func snapshotDecoderRehydratesExactlyWhatClientProduced() async throws {
        // The client no longer owns a decoder of its own: it re-encodes the validated
        // nested map and calls the shared implementation. Decoding those same canonical
        // bytes directly must therefore yield the identical body, for every state kind and
        // for both sides of the predecessor rule.
        let snapshots = [
            snapshotKind0(),
            snapshotKind1(sequence: 1),
            snapshotKind1(sequence: 3),
            snapshotFork(kind: 2, sequence: 2),
            snapshotFork(kind: 3, sequence: 4),
        ]
        for snapshot in snapshots {
            let client = makeClient(status: 200, responseBody: availableBody(snapshot: snapshot))
            let response = try await client.evidence(clientNonce: nonce)
            let rehydrated = try RosterEvidenceClient.decodeSnapshotBody(
                canonicalSnapshotBody: HouseholdCBOR.encode(.map(snapshot))
            )
            #expect(response.snapshotBody == rehydrated)
            #expect(rehydrated.hhId == "hh_test")
            #expect(rehydrated.floorSecs == 100)
        }
    }

    @Test func snapshotDecoderRejectsNonCanonicalBytes() throws {
        // A two-key map emitted with its keys in descending order. It decodes cleanly, but
        // re-encoding sorts the keys, so the byte comparison inside the canonical decoder
        // fails. This shape was chosen because it does not depend on integer-minimality
        // rules, only on key ordering.
        let nonCanonical = Data([0xA2, 0x61, 0x62, 0x01, 0x61, 0x61, 0x02])
        let reencoded = HouseholdCBOR.encode(try HouseholdCBOR.decode(nonCanonical))
        #expect(reencoded != nonCanonical)
        #expect(throws: RosterWireError.nonCanonicalResponse) {
            _ = try RosterEvidenceClient.decodeSnapshotBody(canonicalSnapshotBody: nonCanonical)
        }
    }

    @Test func snapshotDecoderRejectsInvalidKeySet() throws {
        var withExtraKey = snapshotKind0()
        withExtraKey["surprise"] = .unsigned(1)
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try RosterEvidenceClient.decodeSnapshotBody(
                canonicalSnapshotBody: HouseholdCBOR.encode(.map(withExtraKey))
            )
        }
        // The predecessor rule is keyed off the accepted checkpoint's own sequence, so
        // dropping it from a sequence-2 snapshot is a key-set violation, not a nil field.
        var missingPredecessor = snapshotKind1(sequence: 2)
        missingPredecessor["predecessor_checkpoint"] = nil
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try RosterEvidenceClient.decodeSnapshotBody(
                canonicalSnapshotBody: HouseholdCBOR.encode(.map(missingPredecessor))
            )
        }
    }

    @Test func popSignsExactSigningContext() async throws {
        let box = RequestBox()
        let signingBox = SigningBox()
        let client = makeClient(status: 200, responseBody: unavailableBody("unavailable_clock_state"), box: box, signingBox: signingBox)
        _ = try await client.evidence(clientNonce: nonce)
        let req = box.request
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path == "/api/v1/household/roster/evidence")
        #expect(try req?.httpBody == RosterWire.encodeNonceRequest(clientNonce: nonce))
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(req?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        let expected = HouseholdCBOR.requestSigningContext(
            method: "POST",
            pathAndQuery: "/api/v1/household/roster/evidence",
            timestamp: 1_800_000_000,
            bodyHash: HouseholdHash.blake3(try RosterWire.encodeNonceRequest(clientNonce: nonce))
        )
        #expect(signingBox.payload == expected)
    }

    @Test func accepts4Outcomes() async throws {
        let outcomes = ["unavailable_clock_state", "unavailable_owner_authority", "unavailable_checkpoint_stale"]
        for outcome in outcomes {
            let client = makeClient(status: 200, responseBody: unavailableBody(outcome))
            let response = try await client.evidence(clientNonce: nonce)
            #expect(response.outcome == outcome)
        }
        let availableClient = makeClient(status: 200, responseBody: availableBody(snapshot: snapshotKind0()))
        let available = try await availableClient.evidence(clientNonce: nonce)
        #expect(available.outcome == "available")
    }

    @Test func rejectsUnknownOutcome() async {
        let client = makeClient(status: 200, responseBody: unavailableBody("made_up"))
        await #expect(throws: RosterEvidenceClientError.wire(.malformedResponse)) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func rejectsWrongVersion() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(2), "outcome": .text("unavailable_clock_state"),
            "signer_m_id": .text("m_aaa"), "signer_machine_cert": .bytes(Data([0x01])),
            "signer_machine_cert_fingerprint": .bytes(Data(repeating: 0x0C, count: 32)),
            "client_nonce": .bytes(nonce), "signature": .bytes(Data(repeating: 0x0E, count: 64))]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterEvidenceClientError.wire(.malformedResponse)) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func availableDecodes10KeysWithKind0Snapshot() async throws {
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snapshotKind0()))
        let response = try await client.evidence(clientNonce: nonce)
        #expect(response.snapshotBody?.stateKind == 0)
        #expect(response.stateEvidenceDigest == Data(repeating: 0x0A, count: 32))
        #expect(response.fullSnapshotDigest == Data(repeating: 0x0B, count: 32))
        #expect(response.signerMId == "m_aaa")
    }

    @Test func unavailableDecodes7KeysWithoutSnapshotOrDigests() async throws {
        let client = makeClient(status: 200, responseBody: unavailableBody("unavailable_clock_state"))
        let response = try await client.evidence(clientNonce: nonce)
        #expect(response.snapshotBody == nil)
        #expect(response.stateEvidenceDigest == nil)
        #expect(response.fullSnapshotDigest == nil)
    }

    @Test func availableRejectsMissingDigest() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1), "outcome": .text("available"),
            "snapshot_body": .map(snapshotKind0()),
            "full_snapshot_digest": .bytes(Data(repeating: 0x0B, count: 32)),
            "signer_m_id": .text("m_aaa"), "signer_machine_cert": .bytes(Data([0x01])),
            "signer_machine_cert_fingerprint": .bytes(Data(repeating: 0x0C, count: 32)),
            "client_nonce": .bytes(nonce), "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func availableRejectsNullSnapshotBody() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1), "outcome": .text("available"),
            "snapshot_body": .null,
            "state_evidence_digest": .bytes(Data(repeating: 0x0A, count: 32)),
            "full_snapshot_digest": .bytes(Data(repeating: 0x0B, count: 32)),
            "signer_m_id": .text("m_aaa"), "signer_machine_cert": .bytes(Data([0x01])),
            "signer_machine_cert_fingerprint": .bytes(Data(repeating: 0x0C, count: 32)),
            "client_nonce": .bytes(nonce), "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func rejectsWrongTypeSignerMId() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1), "outcome": .text("unavailable_clock_state"),
            "signer_m_id": .unsigned(7), "signer_machine_cert": .bytes(Data([0x01])),
            "signer_machine_cert_fingerprint": .bytes(Data(repeating: 0x0C, count: 32)),
            "client_nonce": .bytes(nonce), "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func unavailableRejectsExtraKey() async {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1), "outcome": .text("unavailable_clock_state"),
            "signer_m_id": .text("m_aaa"), "signer_machine_cert": .bytes(Data([0x01])),
            "signer_machine_cert_fingerprint": .bytes(Data(repeating: 0x0C, count: 32)),
            "client_nonce": .bytes(nonce), "signature": .bytes(Data(repeating: 0x0E, count: 64)),
            "snapshot_body": .map(snapshotKind0()),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func snapshotKind1Seq1NoPredecessor() async throws {
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snapshotKind1(sequence: 1)))
        let response = try await client.evidence(clientNonce: nonce)
        #expect(response.snapshotBody?.stateKind == 1)
        #expect(response.snapshotBody?.predecessorCheckpoint == nil)
        #expect(response.snapshotBody?.conflictingCheckpoint == nil)
    }

    @Test func snapshotKind1SeqGT1RequiresPredecessor() async throws {
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snapshotKind1(sequence: 2)))
        let response = try await client.evidence(clientNonce: nonce)
        #expect(response.snapshotBody?.predecessorCheckpoint != nil)
    }

    @Test func snapshotKind1Seq1ForbidsPredecessor() async {
        var snap = snapshotKind1(sequence: 1)
        snap["predecessor_checkpoint"] = .bytes(checkpointBytes(sequence: 0))
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func snapshotKind1SeqGT1MissingPredecessor() async {
        var snap = snapshotKind1(sequence: 2)
        snap["predecessor_checkpoint"] = nil
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func snapshotKind1ForbidsConflicting() async {
        var snap = snapshotKind1(sequence: 1)
        snap["conflicting_checkpoint"] = .bytes(checkpointBytes(sequence: 1))
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func snapshotForkSeq1Valid() async throws {
        for kind: UInt64 in [2, 3] {
            let client = makeClient(status: 200, responseBody: availableBody(snapshot: snapshotFork(kind: kind, sequence: 1)))
            let response = try await client.evidence(clientNonce: nonce)
            #expect(response.snapshotBody?.stateKind == kind)
            #expect(response.snapshotBody?.conflictingCheckpoint != nil)
            #expect(response.snapshotBody?.predecessorCheckpoint == nil)
        }
    }

    @Test func snapshotForkSeqGT1Valid() async throws {
        for kind: UInt64 in [2, 3] {
            let client = makeClient(status: 200, responseBody: availableBody(snapshot: snapshotFork(kind: kind, sequence: 2)))
            let response = try await client.evidence(clientNonce: nonce)
            #expect(response.snapshotBody?.predecessorCheckpoint != nil)
        }
    }

    @Test func snapshotForkRequiresConflicting() async {
        for kind: UInt64 in [2, 3] {
            var snap = snapshotFork(kind: kind, sequence: 1)
            snap["conflicting_checkpoint"] = nil
            let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
            await #expect(throws: RosterWireError.unexpectedKeySet) {
                _ = try await client.evidence(clientNonce: nonce)
            }
        }
    }

    @Test func snapshotForkSeq1ForbidsPredecessor() async {
        for kind: UInt64 in [2, 3] {
            var snap = snapshotFork(kind: kind, sequence: 1)
            snap["predecessor_checkpoint"] = .bytes(checkpointBytes(sequence: 0))
            let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
            await #expect(throws: RosterWireError.unexpectedKeySet) {
                _ = try await client.evidence(clientNonce: nonce)
            }
        }
    }

    @Test func snapshotForkSeqGT1RequiresPredecessor() async {
        for kind: UInt64 in [2, 3] {
            var snap = snapshotFork(kind: kind, sequence: 2)
            snap["predecessor_checkpoint"] = nil
            let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
            await #expect(throws: RosterWireError.unexpectedKeySet) {
                _ = try await client.evidence(clientNonce: nonce)
            }
        }
    }

    @Test func snapshotRejectsStateKindOutOfRange() async {
        let snap: [String: HouseholdCBORValue] = ["v": .unsigned(1), "hh_id": .text("hh_test"), "state_kind": .unsigned(4), "floor_secs": .unsigned(100)]
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
        await #expect(throws: RosterEvidenceClientError.wire(.malformedResponse)) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func snapshotRejectsNonCanonicalAcceptedCheckpoint() async {
        var snap = snapshotKind1(sequence: 1)
        snap["accepted_checkpoint"] = .bytes(Data([0xA1, 0x61, 0x76, 0x18, 0x01]))
        let client = makeClient(status: 200, responseBody: availableBody(snapshot: snap))
        await #expect(throws: RosterWireError.nonCanonicalResponse) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func rejectsWrongResponseContentType() async {
        let client = makeClient(status: 200, responseBody: unavailableBody("unavailable_clock_state"), contentType: "application/json")
        await #expect(throws: RosterWireError.unsupportedContentType) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func mapsStatusToLiteral() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("not_ready")]))
        let client = makeClient(status: 503, responseBody: body)
        await #expect(throws: RosterEvidenceClientError.wire(.serverError(code: "not_ready"))) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }

    @Test func rejectsUnknownErrorLiteralFor503() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("unavailable")]))
        let client = makeClient(status: 503, responseBody: body)
        await #expect(throws: RosterEvidenceClientError.wire(.malformedResponse)) {
            _ = try await client.evidence(clientNonce: nonce)
        }
    }
}
