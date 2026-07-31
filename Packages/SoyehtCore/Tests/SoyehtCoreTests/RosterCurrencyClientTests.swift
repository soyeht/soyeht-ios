import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

struct RosterCurrencyClientTests {
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

    private let validMachineId = "m_" + String(repeating: "a", count: 52)

    private func makeClient(
        status: Int,
        responseBody: Data,
        contentType: String? = "application/cbor",
        box: RequestBox? = nil,
        signingBox: SigningBox = SigningBox()
    ) -> RosterCurrencyClient {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(box: signingBox),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return RosterCurrencyClient(
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

    private func validMPub() -> Data {
        P256.Signing.PrivateKey().publicKey.compressedRepresentation
    }

    private func neitherBody(_ outcome: String) -> Data {
        HouseholdCBOR.encode(.map(["v": .unsigned(1), "outcome": .text(outcome)]))
    }

    private func activeBody(mId: String, mPub: Data) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("active"),
            "member": .map([
                "m_id": .text(mId),
                "m_pub": .bytes(mPub),
                "machine_cert": .bytes(Data([0x01, 0x02, 0x03])),
                "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            ]),
        ]))
    }

    private func tombstoneMap(mId: String, mPub: Data, reason: UInt64 = 0, cascade: UInt64 = 0) -> [String: HouseholdCBORValue] {
        [
            "v": .unsigned(1),
            "kind": .text("household-machine-roster-revocation/v1"),
            "hh_id": .text("hh_test"),
            "epoch": .bytes(Data(repeating: 0x0B, count: 32)),
            "sequence": .unsigned(1),
            "prev_event_hash": .bytes(Data(repeating: 0x0C, count: 32)),
            "m_id": .text(mId),
            "m_pub": .bytes(mPub),
            "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            "revoked_at": .unsigned(1_800_000_000),
            "reason": .unsigned(reason),
            "cascade": .unsigned(cascade),
            "owner_p_id": .text("p_owner"),
            "owner_cert_fingerprint": .bytes(Data(repeating: 0x0D, count: 32)),
            "owner_person_cert": .bytes(Data([0x09, 0x09])),
            "signature": .bytes(Data(repeating: 0x0E, count: 64)),
        ]
    }

    private func revokedBody(mId: String, mPub: Data, reason: UInt64 = 0, cascade: UInt64 = 0) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("revoked"),
            "tombstone": .map(tombstoneMap(mId: mId, mPub: mPub, reason: reason, cascade: cascade)),
        ]))
    }

    // MARK: - Canonical tombstone retention

    @Test func revokedExposesByteExactCanonicalTombstone() async throws {
        let mPub = validMPub()
        let knownTMap = tombstoneMap(mId: validMachineId, mPub: mPub, reason: 4, cascade: 1)
        // The body is built from the retained map, so production receives exactly this map
        // and nothing else. The expectation is then computed from the same map.
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("revoked"),
            "tombstone": .map(knownTMap),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        let response = try await client.currency(machineId: validMachineId)
        let expected = HouseholdCBOR.encode(.map(knownTMap))
        #expect(response.tombstone?.canonicalTombstone == expected)
        // Byte-exact is the whole point: these bytes are what the owner signed, so they must
        // survive a canonical round trip with the same 16 keys rather than being a map
        // rebuilt from the typed fields.
        let decoded = try RosterWire.decodeCanonical(expected)
        guard case .map(let roundTripped) = decoded else { Issue.record("expected map"); return }
        #expect(roundTripped.keys.sorted() == knownTMap.keys.sorted())
        #expect(roundTripped.count == 16)
        #expect(response.tombstone?.signature == Data(repeating: 0x0E, count: 64))
        #expect(response.tombstone?.reason == 4)
    }

    @Test func activeRejectsTombstonePresent() async {
        let mPub = validMPub()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("active"),
            "member": .map([
                "m_id": .text(validMachineId),
                "m_pub": .bytes(mPub),
                "machine_cert": .bytes(Data([0x01, 0x02, 0x03])),
                "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            ]),
            "tombstone": .map(tombstoneMap(mId: validMachineId, mPub: mPub)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func notListedRejectsTombstonePresent() async {
        let mPub = validMPub()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("not_listed"),
            "tombstone": .map(tombstoneMap(mId: validMachineId, mPub: mPub)),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func rejectsInvalidMachineIdBeforeTransport() async {
        let invalid = [
            "",
            "m_short",
            "x_" + String(repeating: "a", count: 52),
            "m_" + String(repeating: "a", count: 51),
            "m_" + String(repeating: "a", count: 53),
            "m_" + String(repeating: "A", count: 52),
            "m_" + String(repeating: "a", count: 26) + "/" + String(repeating: "a", count: 25),
            "m_" + String(repeating: "a", count: 26) + "?" + String(repeating: "a", count: 25),
            "m_" + String(repeating: "a", count: 26) + "#" + String(repeating: "a", count: 25),
            "m_" + String(repeating: "a", count: 26) + "%" + String(repeating: "a", count: 25),
            "m_" + String(repeating: "1", count: 52),
        ]
        for machineId in invalid {
            let box = RequestBox()
            let client = makeClient(status: 200, responseBody: neitherBody("not_listed"), box: box)
            await #expect(throws: RosterCurrencyClientError.wire(.invalidURL)) {
                _ = try await client.currency(machineId: machineId)
            }
            #expect(box.request == nil)
        }
    }

    @Test func popSignsExactSigningContext() async throws {
        let box = RequestBox()
        let signingBox = SigningBox()
        let client = makeClient(status: 200, responseBody: neitherBody("not_listed"), box: box, signingBox: signingBox)
        _ = try await client.currency(machineId: validMachineId)
        let req = box.request
        #expect(req?.httpMethod == "GET")
        #expect(req?.url?.path == "/api/v1/household/roster/currency/\(validMachineId)")
        #expect(req?.httpBody == nil)
        #expect(req?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:p_owner:") == true)
        let expected = HouseholdCBOR.requestSigningContext(
            method: "GET",
            pathAndQuery: "/api/v1/household/roster/currency/\(validMachineId)",
            timestamp: 1_800_000_000,
            bodyHash: HouseholdHash.blake3(Data())
        )
        #expect(signingBox.payload == expected)
    }

    @Test func acceptsAll9Outcomes() async throws {
        let outcomes = [
            "active", "revoked", "not_listed",
            "unavailable_no_genesis", "unavailable_checkpoint_stale",
            "unavailable_checkpoint_fork_conflict", "unavailable_event_fork_conflict",
            "unavailable_clock_state", "unavailable_owner_authority",
        ]
        let mPub = validMPub()
        for outcome in outcomes {
            let body: Data
            switch outcome {
            case "active": body = activeBody(mId: validMachineId, mPub: mPub)
            case "revoked": body = revokedBody(mId: validMachineId, mPub: mPub)
            default: body = neitherBody(outcome)
            }
            let client = makeClient(status: 200, responseBody: body)
            let response = try await client.currency(machineId: validMachineId)
            #expect(response.outcome == outcome)
        }
    }

    @Test func rejectsUnknownOutcome() async {
        let client = makeClient(status: 200, responseBody: neitherBody("made_up"))
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func rejectsWrongVersion() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(2), "outcome": .text("not_listed")]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func activeDecodesMember4Keys() async throws {
        let mPub = validMPub()
        let client = makeClient(status: 200, responseBody: activeBody(mId: validMachineId, mPub: mPub))
        let response = try await client.currency(machineId: validMachineId)
        #expect(response.member?.mId == validMachineId)
        #expect(response.member?.mPub == mPub)
        #expect(response.member?.machineCert == Data([0x01, 0x02, 0x03]))
        #expect(response.member?.machineCertFingerprint == Data(repeating: 0x0A, count: 32))
        #expect(response.tombstone == nil)
    }

    @Test func activeRejectsMemberIdMismatch() async {
        let mPub = validMPub()
        let otherId = "m_" + String(repeating: "b", count: 52)
        let client = makeClient(status: 200, responseBody: activeBody(mId: otherId, mPub: mPub))
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func activeRejectsOffCurveMPub() async {
        let offCurve = Data([0x02]) + Data(repeating: 0xFF, count: 32)
        let client = makeClient(status: 200, responseBody: activeBody(mId: validMachineId, mPub: offCurve))
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func activeRejectsEmptyMachineCert() async {
        let mPub = validMPub()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("active"),
            "member": .map([
                "m_id": .text(validMachineId),
                "m_pub": .bytes(mPub),
                "machine_cert": .bytes(Data()),
                "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            ]),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func activeRejectsNullMemberField() async {
        let mPub = validMPub()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("active"),
            "member": .map([
                "m_id": .null,
                "m_pub": .bytes(mPub),
                "machine_cert": .bytes(Data([0x01])),
                "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
            ]),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func activeRejectsMemberExtraKey() async {
        let mPub = validMPub()
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "outcome": .text("active"),
            "member": .map([
                "m_id": .text(validMachineId),
                "m_pub": .bytes(mPub),
                "machine_cert": .bytes(Data([0x01])),
                "machine_cert_fingerprint": .bytes(Data(repeating: 0x0A, count: 32)),
                "extra": .text("x"),
            ]),
        ]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func revokedDecodesTombstone16Keys() async throws {
        let mPub = validMPub()
        let client = makeClient(status: 200, responseBody: revokedBody(mId: validMachineId, mPub: mPub, reason: 4, cascade: 1))
        let response = try await client.currency(machineId: validMachineId)
        let t = response.tombstone
        #expect(t?.v == 1)
        #expect(t?.kind == "household-machine-roster-revocation/v1")
        #expect(t?.mId == validMachineId)
        #expect(t?.mPub == mPub)
        #expect(t?.reason == 4)
        #expect(t?.cascade == 1)
        #expect(t?.epoch == Data(repeating: 0x0B, count: 32))
        #expect(t?.signature == Data(repeating: 0x0E, count: 64))
        #expect(t?.ownerPersonCert == Data([0x09, 0x09]))
        #expect(response.member == nil)
    }

    @Test func revokedRejectsWrongKind() async {
        let mPub = validMPub()
        var tMap = tombstoneMap(mId: validMachineId, mPub: mPub)
        tMap["kind"] = .text("wrong-kind")
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "outcome": .text("revoked"), "tombstone": .map(tMap)]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func revokedRejectsReasonOutOfRange() async {
        let mPub = validMPub()
        let body = revokedBody(mId: validMachineId, mPub: mPub, reason: 5)
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func revokedRejectsCascadeOutOfRange() async {
        let mPub = validMPub()
        let body = revokedBody(mId: validMachineId, mPub: mPub, cascade: 2)
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func revokedRejectsIdMismatch() async {
        let mPub = validMPub()
        let otherId = "m_" + String(repeating: "c", count: 52)
        let client = makeClient(status: 200, responseBody: revokedBody(mId: otherId, mPub: mPub))
        await #expect(throws: RosterCurrencyClientError.wire(.malformedResponse)) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func revokedRejectsNullTombstoneField() async {
        let mPub = validMPub()
        var tMap = tombstoneMap(mId: validMachineId, mPub: mPub)
        tMap["owner_p_id"] = .null
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "outcome": .text("revoked"), "tombstone": .map(tMap)]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func revokedRejectsBadSignatureLength() async {
        let mPub = validMPub()
        var tMap = tombstoneMap(mId: validMachineId, mPub: mPub)
        tMap["signature"] = .bytes(Data(repeating: 0x0E, count: 32))
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "outcome": .text("revoked"), "tombstone": .map(tMap)]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func neitherOutcomeHasNoMemberOrTombstone() async throws {
        let client = makeClient(status: 200, responseBody: neitherBody("not_listed"))
        let response = try await client.currency(machineId: validMachineId)
        #expect(response.member == nil)
        #expect(response.tombstone == nil)
    }

    @Test func neitherRejectsExtraKey() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "outcome": .text("not_listed"), "member": .map([:])]))
        let client = makeClient(status: 200, responseBody: body)
        await #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func rejectsWrongResponseContentType() async {
        let client = makeClient(status: 200, responseBody: neitherBody("not_listed"), contentType: "application/json")
        await #expect(throws: RosterWireError.unsupportedContentType) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }

    @Test func mapsStatusToLiteral() async {
        let body = HouseholdCBOR.encode(.map(["v": .unsigned(1), "error": .text("invalid_machine_id")]))
        let client = makeClient(status: 400, responseBody: body)
        await #expect(throws: RosterCurrencyClientError.wire(.serverError(code: "invalid_machine_id"))) {
            _ = try await client.currency(machineId: validMachineId)
        }
    }
}
