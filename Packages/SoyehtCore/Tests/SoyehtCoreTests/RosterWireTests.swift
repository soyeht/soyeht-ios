import Foundation
import Testing

@testable import SoyehtCore

struct RosterWireTests {
    @Test func contentTypeAcceptsExactCBOR() {
        #expect(throws: Never.self) {
            try RosterWire.validateResponseContentType("application/cbor")
        }
    }

    @Test func contentTypeRejectsCBORWithCharset() {
        #expect(throws: RosterWireError.unsupportedContentType) {
            try RosterWire.validateResponseContentType("application/cbor; charset=utf-8")
        }
    }

    @Test func contentTypeRejectsJSON() {
        #expect(throws: RosterWireError.unsupportedContentType) {
            try RosterWire.validateResponseContentType("application/json")
        }
    }

    @Test func contentTypeRejectsMissing() {
        #expect(throws: RosterWireError.unsupportedContentType) {
            try RosterWire.validateResponseContentType(nil)
        }
    }

    @Test func contentTypeRejectsDuplicate() {
        #expect(throws: RosterWireError.unsupportedContentType) {
            try RosterWire.validateResponseContentType("application/cbor, application/cbor")
        }
    }

    @Test func decodeCanonicalAcceptsCanonicalBytes() throws {
        let canonical = HouseholdCBOR.encode(.map(["v": .unsigned(1)]))
        #expect(throws: Never.self) {
            _ = try RosterWire.decodeCanonical(canonical)
        }
    }

    @Test func decodeCanonicalRejectsMalformed() {
        #expect(throws: RosterWireError.malformedResponse) {
            _ = try RosterWire.decodeCanonical(Data([0xFF, 0xFE]))
        }
    }

    @Test func errorEnvelopeExactKeyset() {
        let envelope = HouseholdCBOR.encode(.map([
            "error": .text("unauthenticated"),
            "v": .unsigned(1),
        ]))
        let err = RosterWire.decodeErrorEnvelope(envelope)
        #expect(err == .serverError(code: "unauthenticated"))
    }

    @Test func errorEnvelopeRejectsExtraKey() {
        let envelope = HouseholdCBOR.encode(.map([
            "error": .text("unauthenticated"),
            "message": .text("extra"),
            "v": .unsigned(1),
        ]))
        let err = RosterWire.decodeErrorEnvelope(envelope)
        #expect(err == .malformedResponse)
    }

    @Test func errorEnvelopeRejectsWrongVersion() {
        let envelope = HouseholdCBOR.encode(.map([
            "error": .text("unauthenticated"),
            "v": .unsigned(2),
        ]))
        let err = RosterWire.decodeErrorEnvelope(envelope)
        #expect(err == .malformedResponse)
    }

    @Test func requireExactKeysRejectsExtra() {
        let map: [String: HouseholdCBORValue] = [
            "outcome": .text("accepted"),
            "v": .unsigned(1),
            "extra": .text("bad"),
        ]
        #expect(throws: RosterWireError.unexpectedKeySet) {
            try RosterWire.requireExactKeys(map, ["v", "outcome"])
        }
    }

    @Test func requireExactKeysRejectsMissing() {
        let map: [String: HouseholdCBORValue] = ["v": .unsigned(1)]
        #expect(throws: RosterWireError.unexpectedKeySet) {
            try RosterWire.requireExactKeys(map, ["v", "outcome"])
        }
    }

    @Test func requireExactKeysAcceptsExact() throws {
        let map: [String: HouseholdCBORValue] = [
            "outcome": .text("accepted"),
            "v": .unsigned(1),
        ]
        #expect(throws: Never.self) {
            try RosterWire.requireExactKeys(map, ["outcome", "v"])
        }
    }

    @Test func nonceRequestEncodesCanonical32B() throws {
        let nonce = Data(repeating: 0xAA, count: 32)
        let encoded = try RosterWire.encodeNonceRequest(clientNonce: nonce)
        let decoded = try HouseholdCBOR.decode(encoded)
        guard case .map(let map) = decoded else {
            Issue.record("expected map")
            return
        }
        #expect(map.count == 2)
        guard case .unsigned(let v) = map["v"] else {
            Issue.record("expected v")
            return
        }
        #expect(v == 1)
        guard case .bytes(let n) = map["client_nonce"] else {
            Issue.record("expected client_nonce")
            return
        }
        #expect(n == nonce)
        #expect(HouseholdCBOR.encode(decoded) == encoded)
    }

    @Test func nonceRequestRejects31Bytes() {
        #expect(throws: RosterWireError.malformedResponse) {
            _ = try RosterWire.encodeNonceRequest(clientNonce: Data(repeating: 0xAA, count: 31))
        }
    }

    @Test func nonceRequestRejects33Bytes() {
        #expect(throws: RosterWireError.malformedResponse) {
            _ = try RosterWire.encodeNonceRequest(clientNonce: Data(repeating: 0xAA, count: 33))
        }
    }

    @Test func decodeCanonicalRejectsGenuineNonCanonical() {
        // uint 1 encoded as 0x18 0x01 (2-byte) instead of canonical 0x01 (1-byte)
        let nonCanonical = Data([0xA1, 0x61, 0x76, 0x18, 0x01])
        #expect(throws: RosterWireError.nonCanonicalResponse) {
            _ = try RosterWire.decodeCanonical(nonCanonical)
        }
    }

    @Test func errorEnvelopeRejectsNonCanonical() {
        // {v: 1, error: "x"} with v encoded as 0x18 0x01 (non-canonical)
        let nonCanonical = Data([0xA2, 0x61, 0x76, 0x18, 0x01, 0x65, 0x65, 0x72, 0x72, 0x6F, 0x72, 0x61, 0x78])
        let err = RosterWire.decodeErrorEnvelope(nonCanonical)
        #expect(err == .malformedResponse)
    }

    @Test func requireBytes32RejectsWrongLength() {
        let map: [String: HouseholdCBORValue] = ["fp": .bytes(Data(repeating: 0, count: 16))]
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try RosterWire.requireBytes32(map, "fp")
        }
    }

    @Test func requireBytes64RejectsWrongLength() {
        let map: [String: HouseholdCBORValue] = ["sig": .bytes(Data(repeating: 0, count: 32))]
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try RosterWire.requireBytes64(map, "sig")
        }
    }

    @Test func endpointURLRejectsQuery() throws {
        let base = URL(string: "http://192.0.2.10:8101")!
        let (url, path) = try RosterWire.endpointURL(baseURL: base, path: "/api/v1/household/roster/admit")
        #expect(url.absoluteString == "http://192.0.2.10:8101/api/v1/household/roster/admit")
        #expect(path == "/api/v1/household/roster/admit")
        #expect(url.query == nil)
    }

    @Test func endpointURLRejectsBaseQuery() {
        let base = URL(string: "http://192.0.2.10:8101?foo=bar")!
        #expect(throws: RosterWireError.invalidURL) {
            _ = try RosterWire.endpointURL(baseURL: base, path: "/api/v1/household/roster/admit")
        }
    }

    @Test func endpointURLRejectsBaseFragment() {
        let base = URL(string: "http://192.0.2.10:8101#frag")!
        #expect(throws: RosterWireError.invalidURL) {
            _ = try RosterWire.endpointURL(baseURL: base, path: "/api/v1/household/roster/admit")
        }
    }

    @Test func endpointURLRejectsPathWithQuery() {
        let base = URL(string: "http://192.0.2.10:8101")!
        #expect(throws: RosterWireError.invalidURL) {
            _ = try RosterWire.endpointURL(baseURL: base, path: "/api/v1/household/roster/admit?x=1")
        }
    }

    @Test func endpointURLRejectsPathWithFragment() {
        let base = URL(string: "http://192.0.2.10:8101")!
        #expect(throws: RosterWireError.invalidURL) {
            _ = try RosterWire.endpointURL(baseURL: base, path: "/api/v1/household/roster/admit#frag")
        }
    }

    @Test func errorEnvelopeAcceptsKnownLiteral() {
        let envelope = HouseholdCBOR.encode(.map([
            "error": .text("integrity_epoch"),
            "v": .unsigned(1),
        ]))
        let err = RosterWire.decodeErrorEnvelope(envelope)
        #expect(err == .serverError(code: "integrity_epoch"))
    }

    @Test func errorEnvelopeRejectsUnknownLiteral() {
        let envelope = HouseholdCBOR.encode(.map([
            "error": .text("made_up_error"),
            "v": .unsigned(1),
        ]))
        let err = RosterWire.decodeErrorEnvelope(envelope)
        #expect(err == .malformedResponse)
    }

    @Test func projectionNoGenesisExact() throws {
        let p = try VerifiedRosterProjection(
            stateKind: 0, hhId: "hh_test", epoch: nil,
            checkpointSequence: nil, eventSequence: nil,
            issuedAt: nil, notAfter: nil, floorSecs: 100,
            activeMembers: [], tombstones: [],
            checkpointBytes: nil, ownerCertFingerprint: nil,
            genesisCheckpointHash: nil,
            eventHashes: [],
            conflictingCheckpointBytes: nil
        )
        #expect(p.stateKind == 0)
        #expect(p.activeMembers.isEmpty)
    }

    @Test func projectionNoGenesisRejectsEpoch() {
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try VerifiedRosterProjection(
                stateKind: 0, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                checkpointSequence: nil, eventSequence: nil,
                issuedAt: nil, notAfter: nil, floorSecs: 100,
                activeMembers: [], tombstones: [],
                checkpointBytes: nil, ownerCertFingerprint: nil,
                genesisCheckpointHash: nil,
                eventHashes: [],
                conflictingCheckpointBytes: nil
            )
        }
    }

    @Test func projectionAcceptedRejectsMissingRequired() {
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try VerifiedRosterProjection(
                stateKind: 1, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                checkpointSequence: 1, eventSequence: 0,
                issuedAt: 1000, notAfter: nil, floorSecs: 100,
                activeMembers: [], tombstones: [],
                checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                eventHashes: [],
                conflictingCheckpointBytes: nil
            )
        }
    }

    @Test func projectionAcceptedRejectsConflicting() {
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try VerifiedRosterProjection(
                stateKind: 1, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                checkpointSequence: 1, eventSequence: 0,
                issuedAt: 1000, notAfter: 1300, floorSecs: 100,
                activeMembers: [], tombstones: [],
                checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                eventHashes: [],
                conflictingCheckpointBytes: Data([2])
            )
        }
    }

    @Test func projectionForkRequiresConflicting() {
        for kind: UInt8 in [2, 3] {
            #expect(throws: RosterWireError.unexpectedKeySet) {
                _ = try VerifiedRosterProjection(
                    stateKind: kind, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                    checkpointSequence: 2, eventSequence: 1,
                    issuedAt: 1000, notAfter: 1300, floorSecs: 100,
                    activeMembers: [], tombstones: ["m_gone"],
                    checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                    genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                    eventHashes: [Data(repeating: 0xAB, count: 32)],
                    conflictingCheckpointBytes: nil
                )
            }
        }
    }

    @Test func projectionRejectsUnsortedMembers() throws {
        let m1 = try VerifiedMachineMember(mId: "m_bbb", mPub: Data(repeating: 2, count: 33), certBytes: Data([1]), certFingerprint: Data(repeating: 0, count: 32))
        let m2 = try VerifiedMachineMember(mId: "m_aaa", mPub: Data(repeating: 3, count: 33), certBytes: Data([2]), certFingerprint: Data(repeating: 1, count: 32))
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try VerifiedRosterProjection(
                stateKind: 1, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                checkpointSequence: 1, eventSequence: 0,
                issuedAt: 1000, notAfter: 1300, floorSecs: 100,
                activeMembers: [m1, m2], tombstones: [],
                checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                eventHashes: [],
                conflictingCheckpointBytes: nil
            )
        }
    }

    @Test func projectionRejectsDuplicateMembers() throws {
        let m1 = try VerifiedMachineMember(mId: "m_aaa", mPub: Data(repeating: 2, count: 33), certBytes: Data([1]), certFingerprint: Data(repeating: 0, count: 32))
        let m2 = try VerifiedMachineMember(mId: "m_aaa", mPub: Data(repeating: 3, count: 33), certBytes: Data([2]), certFingerprint: Data(repeating: 1, count: 32))
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try VerifiedRosterProjection(
                stateKind: 1, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                checkpointSequence: 1, eventSequence: 0,
                issuedAt: 1000, notAfter: 1300, floorSecs: 100,
                activeMembers: [m1, m2], tombstones: [],
                checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                eventHashes: [],
                conflictingCheckpointBytes: nil
            )
        }
    }

    @Test func projectionRejectsEventHashCountMismatchAgainstTombstones() throws {
        // Every other field is coherent for each kind, including the event sequence, which
        // matches the hash count. The single broken invariant is that the hash list does
        // not cover the tombstones, so that is the only reason left to reject. As always
        // in this type the error value is shared, so the isolation is by construction.
        for kind: UInt8 in [1, 2, 3] {
            #expect(throws: RosterWireError.unexpectedKeySet) {
                _ = try VerifiedRosterProjection(
                    stateKind: kind, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                    checkpointSequence: 2, eventSequence: 0,
                    issuedAt: 1000, notAfter: 1300, floorSecs: 100,
                    activeMembers: [], tombstones: ["m_gone"],
                    checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                    genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                    eventHashes: [],
                    conflictingCheckpointBytes: kind == 1 ? nil : Data([2])
                )
            }
        }
    }

    @Test func projectionRejectsEventHashCountMismatchAgainstEventSequence() throws {
        // The other leg of the same invariant, and the vacuity-critical one: here the hash
        // list DOES cover the tombstones, both being empty, so that condition passes. The
        // only thing broken is that the event sequence claims one applied event while the
        // hash list carries none, which is exactly the shape a count-only check would let
        // through.
        for kind: UInt8 in [1, 2, 3] {
            #expect(throws: RosterWireError.unexpectedKeySet) {
                _ = try VerifiedRosterProjection(
                    stateKind: kind, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                    checkpointSequence: 2, eventSequence: 1,
                    issuedAt: 1000, notAfter: 1300, floorSecs: 100,
                    activeMembers: [], tombstones: [],
                    checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                    genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                    eventHashes: [],
                    conflictingCheckpointBytes: kind == 1 ? nil : Data([2])
                )
            }
        }
    }

    @Test func projectionRejectsMemberTombstoneOverlap() throws {
        let m1 = try VerifiedMachineMember(mId: "m_aaa", mPub: Data(repeating: 2, count: 33), certBytes: Data([1]), certFingerprint: Data(repeating: 0, count: 32))
        #expect(throws: RosterWireError.unexpectedKeySet) {
            _ = try VerifiedRosterProjection(
                stateKind: 1, hhId: "hh_test", epoch: Data(repeating: 0, count: 32),
                checkpointSequence: 1, eventSequence: 1,
                issuedAt: 1000, notAfter: 1300, floorSecs: 100,
                activeMembers: [m1], tombstones: ["m_aaa"],
                checkpointBytes: Data([1]), ownerCertFingerprint: Data(repeating: 0, count: 32),
                genesisCheckpointHash: Data(repeating: 0xEE, count: 32),
                eventHashes: [Data(repeating: 0xAB, count: 32)],
                conflictingCheckpointBytes: nil
            )
        }
    }
}
