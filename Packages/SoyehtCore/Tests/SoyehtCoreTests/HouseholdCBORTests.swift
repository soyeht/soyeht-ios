import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdCBOR")
struct HouseholdCBORTests {
    @Test func pairingProofContextIsCanonicalAndRoundTrips() throws {
        let nonce = Data([1, 2, 3])
        let pPub = HouseholdTestFixtures.publicKey(byte: 0x44)
        let first = HouseholdCBOR.pairingProofContext(
            householdId: "hh_test",
            nonce: nonce,
            personPublicKey: pPub
        )
        let second = HouseholdCBOR.pairingProofContext(
            householdId: "hh_test",
            nonce: nonce,
            personPublicKey: pPub
        )

        #expect(first == second)
        #expect(try HouseholdCBOR.encode(HouseholdCBOR.decode(first)) == first)
    }

    @Test func requestSigningContextChangesWhenInputsChange() {
        let bodyHash = Data(repeating: 0, count: 32)
        let get = HouseholdCBOR.requestSigningContext(
            method: "GET",
            pathAndQuery: "/api/v1/household/snapshot",
            timestamp: 1,
            bodyHash: bodyHash
        )
        let post = HouseholdCBOR.requestSigningContext(
            method: "POST",
            pathAndQuery: "/api/v1/household/snapshot",
            timestamp: 1,
            bodyHash: bodyHash
        )
        #expect(get != post)
    }

    @Test func joinChallengeIsDeterministicAndKeysAreLexOrdered() throws {
        let mPub = HouseholdTestFixtures.publicKey(byte: 0x55)
        let nonce = Data(repeating: 0xAB, count: 32)
        let firstEncoding = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: "studio.local",
            platform: "macos"
        )
        let secondEncoding = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: "studio.local",
            platform: "macos"
        )
        #expect(firstEncoding == secondEncoding)

        let decoded = try HouseholdCBOR.decode(firstEncoding)
        guard case .map(let map) = decoded else {
            Issue.record("expected JoinChallenge to decode as a CBOR map")
            return
        }
        #expect(map["v"] == .unsigned(1))
        #expect(map["purpose"] == .text("machine-join-request"))
        #expect(map["m_pub"] == .bytes(mPub))
        #expect(map["nonce"] == .bytes(nonce))
        #expect(map["hostname"] == .text("studio.local"))
        #expect(map["platform"] == .text("macos"))

        // Round-trip MUST yield byte-identical canonical bytes.
        #expect(HouseholdCBOR.encode(decoded) == firstEncoding)
    }

    @Test func joinChallengeChangesWhenAnyBoundFieldChanges() {
        let mPub = HouseholdTestFixtures.publicKey(byte: 0x10)
        let nonce = Data(repeating: 0x01, count: 32)
        let baseline = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: "studio.local",
            platform: "macos"
        )
        // Each variant MUST produce a different encoding so signature
        // verification fails on tamper (FR-029 anti-phishing).
        let mutatedHostname = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: "studio.lan",
            platform: "macos"
        )
        let mutatedPlatform = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: nonce,
            hostname: "studio.local",
            platform: "linux-nix"
        )
        let mutatedKey = HouseholdCBOR.joinChallenge(
            machinePublicKey: HouseholdTestFixtures.publicKey(byte: 0x11),
            nonce: nonce,
            hostname: "studio.local",
            platform: "macos"
        )
        let mutatedNonce = HouseholdCBOR.joinChallenge(
            machinePublicKey: mPub,
            nonce: Data(repeating: 0x02, count: 32),
            hostname: "studio.local",
            platform: "macos"
        )
        #expect(baseline != mutatedHostname)
        #expect(baseline != mutatedPlatform)
        #expect(baseline != mutatedKey)
        #expect(baseline != mutatedNonce)
    }

    @Test func joinChallengeMapKeysAreEncodedInCanonicalLengthFirstOrder() throws {
        let encoded = HouseholdCBOR.joinChallenge(
            machinePublicKey: HouseholdTestFixtures.publicKey(byte: 0x33),
            nonce: Data(repeating: 0x77, count: 32),
            hostname: "h",
            platform: "macos"
        )
        // RFC 8949 §4.2.1 deterministic encoding: keys sorted by encoded
        // bytewise lex, which is equivalent to length-first then byte-lex.
        // For JoinChallenge the order is therefore: v (1), m_pub (5), nonce (5),
        // purpose (7), hostname (8), platform (8).
        let bytes = Array(encoded)
        #expect(bytes[0] == 0xA6)        // map(6)
        #expect(bytes[1] == 0x61)        // text(1)
        #expect(bytes[2] == 0x76)        // "v"
        #expect(bytes[3] == 0x01)        // unsigned(1)
    }

    @Test func decodeHandlesDataSlicesWithNonZeroStartIndex() throws {
        let nested = HouseholdCBOR.encode(.map([
            "ok": .bool(true),
            "v": .unsigned(1),
        ]))
        let encoded = HouseholdCBOR.encode(.map([
            "payload": .bytes(nested),
            "v": .unsigned(1),
        ]))
        let prefixed = Data([0xFF]) + encoded
        let sliced = prefixed[prefixed.index(after: prefixed.startIndex)..<prefixed.endIndex]

        guard case .map(let map) = try HouseholdCBOR.decode(sliced) else {
            Issue.record("expected sliced CBOR to decode as a map")
            return
        }
        #expect(map["v"] == .unsigned(1))
        guard case .bytes(let payload) = map["payload"],
              case .map(let nestedMap) = try HouseholdCBOR.decode(payload) else {
            Issue.record("expected nested byte string CBOR to decode")
            return
        }
        #expect(nestedMap["ok"] == .bool(true))
    }

    @Test func ownerApprovalContextIsDeterministicAndCarriesAllSevenFields() throws {
        let challengeSig = Data(repeating: 0x9C, count: 64)
        let context = HouseholdCBOR.ownerApprovalContext(
            householdId: "hh_test",
            ownerPersonId: "p_owner",
            cursor: 42,
            challengeSignature: challengeSig,
            timestamp: 1_700_000_000
        )
        #expect(context == HouseholdCBOR.ownerApprovalContext(
            householdId: "hh_test",
            ownerPersonId: "p_owner",
            cursor: 42,
            challengeSignature: challengeSig,
            timestamp: 1_700_000_000
        ))

        let decoded = try HouseholdCBOR.decode(context)
        guard case .map(let map) = decoded else {
            Issue.record("expected OwnerApprovalContext to decode as a CBOR map")
            return
        }
        #expect(map["v"] == .unsigned(1))
        #expect(map["purpose"] == .text("owner-approve-join"))
        #expect(map["hh_id"] == .text("hh_test"))
        #expect(map["p_id"] == .text("p_owner"))
        #expect(map["cursor"] == .unsigned(42))
        #expect(map["challenge_sig"] == .bytes(challengeSig))
        #expect(map["timestamp"] == .unsigned(1_700_000_000))
        #expect(HouseholdCBOR.encode(decoded) == context)
    }

    @Test func ownerApprovalContextChangesWhenAnyFieldChanges() {
        let challengeSig = Data(repeating: 0x33, count: 64)
        let baseline = HouseholdCBOR.ownerApprovalContext(
            householdId: "hh_a",
            ownerPersonId: "p_a",
            cursor: 1,
            challengeSignature: challengeSig,
            timestamp: 100
        )
        // Cursor mutation must change the signing input — protects against
        // gossip-replay reordering attacks.
        let differentCursor = HouseholdCBOR.ownerApprovalContext(
            householdId: "hh_a",
            ownerPersonId: "p_a",
            cursor: 2,
            challengeSignature: challengeSig,
            timestamp: 100
        )
        // Timestamp mutation invalidates the ±60s replay window.
        let differentTimestamp = HouseholdCBOR.ownerApprovalContext(
            householdId: "hh_a",
            ownerPersonId: "p_a",
            cursor: 1,
            challengeSignature: challengeSig,
            timestamp: 200
        )
        // Challenge_sig mutation breaks the transitive binding to the candidate.
        let differentChallengeSig = HouseholdCBOR.ownerApprovalContext(
            householdId: "hh_a",
            ownerPersonId: "p_a",
            cursor: 1,
            challengeSignature: Data(repeating: 0x44, count: 64),
            timestamp: 100
        )
        #expect(baseline != differentCursor)
        #expect(baseline != differentTimestamp)
        #expect(baseline != differentChallengeSig)
    }

    @Test func ownerApprovalBodyIsDeterministicAndCarriesThreeFields() throws {
        let approvalSig = Data(repeating: 0xEE, count: 64)
        let body = HouseholdCBOR.ownerApprovalBody(cursor: 7, approvalSignature: approvalSig)
        #expect(body == HouseholdCBOR.ownerApprovalBody(cursor: 7, approvalSignature: approvalSig))

        let decoded = try HouseholdCBOR.decode(body)
        guard case .map(let map) = decoded else {
            Issue.record("expected OwnerApproval to decode as a CBOR map")
            return
        }
        #expect(map.count == 3)
        #expect(map["v"] == .unsigned(1))
        #expect(map["cursor"] == .unsigned(7))
        #expect(map["approval_sig"] == .bytes(approvalSig))
        #expect(HouseholdCBOR.encode(decoded) == body)
    }

    @Test func ownerApprovalBodyMapKeysAreEncodedInCanonicalLengthFirstOrder() throws {
        let body = HouseholdCBOR.ownerApprovalBody(
            cursor: 1,
            approvalSignature: Data(repeating: 0x10, count: 64)
        )
        // RFC 8949 §4.2.1 length-first byte-lex order yields:
        // v (1), cursor (6), approval_sig (12).
        let bytes = Array(body)
        #expect(bytes[0] == 0xA3)        // map(3)
        #expect(bytes[1] == 0x61)        // text(1)
        #expect(bytes[2] == 0x76)        // "v"
        #expect(bytes[3] == 0x01)        // unsigned(1)
        #expect(bytes[4] == 0x66)        // text(6)
        #expect(Array(bytes[5..<11]) == Array("cursor".utf8))
    }

    @Test func localAnchorIsDeterministicAndDecodesToExpectedFields() throws {
        let secret = Data(repeating: 0xAA, count: 32)
        let hhId = "hh_eeit7s5ak64oy4cr"
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x42)
        let firstEncoding = HouseholdCBOR.localAnchor(
            anchorSecret: secret,
            householdId: hhId,
            householdPublicKey: hhPub
        )
        let secondEncoding = HouseholdCBOR.localAnchor(
            anchorSecret: secret,
            householdId: hhId,
            householdPublicKey: hhPub
        )
        #expect(firstEncoding == secondEncoding)

        guard case .map(let map) = try HouseholdCBOR.decode(firstEncoding) else {
            Issue.record("expected LocalAnchor to decode as a CBOR map")
            return
        }
        #expect(map.count == 4)
        #expect(map["v"] == .unsigned(1))
        #expect(map["anchor_secret"] == .bytes(secret))
        #expect(map["hh_id"] == .text(hhId))
        #expect(map["hh_pub"] == .bytes(hhPub))

        // Round-trip MUST yield byte-identical canonical bytes — the server
        // re-encodes and byte-equals-checks per the contract.
        #expect(HouseholdCBOR.encode(.map(map)) == firstEncoding)
    }

    @Test func localAnchorMapKeysAreEncodedInCanonicalLengthFirstOrder() throws {
        let body = HouseholdCBOR.localAnchor(
            anchorSecret: Data(repeating: 0x01, count: 32),
            householdId: "hh_a",
            householdPublicKey: HouseholdTestFixtures.publicKey(byte: 0x77)
        )
        // RFC 8949 §4.2.1 length-first byte-lex order: v (1), hh_id (5),
        // hh_pub (6), anchor_secret (13).
        let bytes = Array(body)
        #expect(bytes[0] == 0xA4)        // map(4)
        #expect(bytes[1] == 0x61)        // text(1)
        #expect(bytes[2] == 0x76)        // "v"
        #expect(bytes[3] == 0x01)        // unsigned(1)
        #expect(bytes[4] == 0x65)        // text(5)
        #expect(Array(bytes[5..<10]) == Array("hh_id".utf8))
    }
}
