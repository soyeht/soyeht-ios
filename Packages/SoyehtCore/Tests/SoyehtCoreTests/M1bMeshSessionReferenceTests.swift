import Foundation
@testable import SoyehtCore
import Testing

// M1b slice-2 vectors: the mesh-session constants and the three frozen
// composition formulas, pinned to hand-derived bytes. The frame maps here
// are deliberately SYNTHETIC minimal maps, not full ProofR/intent schemas —
// these vectors freeze the composition rules (preimage assembly, digest
// domain separation, canonical ordering) on the Swift side; the full
// per-frame schema bytes arrive with the Rust-emitted corpus and are
// compared against this same machinery.
@Suite("M1b mesh-session Swift reference vectors")
struct M1bMeshSessionReferenceTests {
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // {"sig": h'AABB', "role": "responder",
    //  "domain": "soyeht/mesh-session/v1", "protocol_version": 1}
    // Canonical order is by encoded-key bytes, so the length-first result is
    // sig(0x63…) < role(0x64…) < domain(0x66…) < protocol_version(0x70…).
    private static let frameMap = HouseholdCBORValue.map([
        "sig": .bytes(Data([0xAA, 0xBB])),
        "role": .text("responder"),
        "domain": .text("soyeht/mesh-session/v1"),
        "protocol_version": .unsigned(1),
    ])
    private static let frameFullHex =
        "a46373696742aabb64726f6c6569726573706f6e64657266646f6d61696e"
        + "76736f796568742f6d6573682d73657373696f6e2f7631"
        + "7070726f746f636f6c5f76657273696f6e01"
    private static let frameUnsignedHex =
        "a364726f6c6569726573706f6e64657266646f6d61696e"
        + "76736f796568742f6d6573682d73657373696f6e2f7631"
        + "7070726f746f636f6c5f76657273696f6e01"
    private static let frameDigestHex =
        "7adce92ebea5456a1195ccb8984f17d734ae2a31ce5c93653913990494051d69"

    // {"sig": h'CC', "kind": "intent"}
    private static let intentMap = HouseholdCBORValue.map([
        "sig": .bytes(Data([0xCC])),
        "kind": .text("intent"),
    ])
    private static let intentFullHex = "a26373696741cc646b696e6466696e74656e74"
    private static let intentDigestHex =
        "520c88ed32625eaf38a427976fa5be06aeffe504b6a49eaeb4b4ebe9491710e9"

    @Test
    func constantsMatchTheRustContract() {
        #expect(M1bMeshSessionWire.typeProofR == 0x01)
        #expect(M1bMeshSessionWire.typeProofI == 0x02)
        #expect(M1bMeshSessionWire.typeFinalConfirm == 0x03)
        #expect(M1bMeshSessionWire.typeActivate == 0x04)
        #expect(M1bMeshSessionWire.typeActivateAck == 0x05)
        #expect(M1bMeshSessionWire.intentTypeByte == 0x06)
        #expect(M1bMeshSessionWire.capabilityTypeByteReserved == 0x07)
        #expect(M1bMeshSessionWire.protocolVersion == 1)
        #expect(M1bMeshSessionWire.domain == "soyeht/mesh-session/v1")
        #expect(M1bMeshSessionWire.intentDomain == "soyeht/mesh-connection-intent/v1")
        #expect(M1bMeshSessionWire.roleResponder == "responder")
        #expect(M1bMeshSessionWire.roleInitiator == "initiator")
        #expect(M1bMeshSessionWire.kindFinalConfirm == "final-confirm")
        #expect(M1bMeshSessionWire.kindActivate == "activate")
        #expect(M1bMeshSessionWire.kindActivateAck == "activate-ack")
        // The record-limit arithmetic, not just the endpoints: plaintext is
        // the noise record minus the Poly1305 tag, and the CBOR body
        // additionally loses the leading type byte.
        #expect(M1bMeshSessionWire.maxPlaintextLen == 65_519)
        #expect(M1bMeshSessionWire.maxCBORBodyLen == 65_518)
        #expect(M1bMeshSessionWire.connectionIntentDigestLength == 32)
    }

    @Test
    func canonicalFrameBytesAndSigningPreimageMatchTheirPins() throws {
        let full = HouseholdCBOR.encode(Self.frameMap)
        #expect(Self.hex(full) == Self.frameFullHex)

        let preimage = try M1bMeshSessionWire.signingPreimage(
            typeByte: M1bMeshSessionWire.typeProofR,
            fullFrame: full
        )
        #expect(Self.hex(preimage) == "01" + Self.frameUnsignedHex)
    }

    @Test
    func frameDigestPrependsTheTypeByteOverFullBytesIncludingSig() {
        let full = HouseholdCBOR.encode(Self.frameMap)
        let digest = M1bMeshSessionWire.frameDigest(
            typeByte: M1bMeshSessionWire.typeProofR,
            fullFrame: full
        )
        #expect(Self.hex(digest) == Self.frameDigestHex)
    }

    @Test
    func intentDigestPrependsTheAsciiDomainAndNoTypeByte() {
        let full = HouseholdCBOR.encode(Self.intentMap)
        #expect(Self.hex(full) == Self.intentFullHex)
        #expect(
            Self.hex(M1bMeshSessionWire.intentDigest(fullIntent: full))
                == Self.intentDigestHex
        )
        // The two digest formulas are genuinely different paths: collapsing
        // them into one (type byte for both, or domain string for both)
        // must break this vector.
        #expect(
            M1bMeshSessionWire.frameDigest(
                typeByte: M1bMeshSessionWire.intentTypeByte,
                fullFrame: full
            )
                != M1bMeshSessionWire.intentDigest(fullIntent: full)
        )
    }

    // Two frames differing only in `sig` share a signing preimage but must
    // digest differently — the digest covers I_full INCLUDING sig.
    @Test
    func sigOnlyDifferenceKeepsPreimageAndChangesDigest() throws {
        let base = HouseholdCBOR.encode(Self.frameMap)
        let resigned = HouseholdCBOR.encode(.map([
            "sig": .bytes(Data([0xDD, 0xEE])),
            "role": .text("responder"),
            "domain": .text("soyeht/mesh-session/v1"),
            "protocol_version": .unsigned(1),
        ]))
        #expect(base != resigned)
        let preimageA = try M1bMeshSessionWire.signingPreimage(
            typeByte: M1bMeshSessionWire.typeProofR, fullFrame: base
        )
        let preimageB = try M1bMeshSessionWire.signingPreimage(
            typeByte: M1bMeshSessionWire.typeProofR, fullFrame: resigned
        )
        #expect(preimageA == preimageB)
        #expect(
            M1bMeshSessionWire.frameDigest(
                typeByte: M1bMeshSessionWire.typeProofR, fullFrame: base
            )
                != M1bMeshSessionWire.frameDigest(
                    typeByte: M1bMeshSessionWire.typeProofR, fullFrame: resigned
                )
        )
    }

    // Rust's unsigned_preimage_body fails without exactly one sig entry;
    // HouseholdCBOR.canonicalMapWithoutKey alone would silently no-op, so
    // the reference enforces the Rust rule and this pin keeps it enforced.
    @Test
    func sigLessFrameCannotProduceASigningPreimage() {
        let sigless = HouseholdCBOR.encode(.map(["role": .text("responder")]))
        #expect(throws: M1bMeshSessionWireError.missingSigField) {
            try M1bMeshSessionWire.signingPreimage(
                typeByte: M1bMeshSessionWire.typeProofR, fullFrame: sigless
            )
        }
    }

    // v6 §3: the body map is closed against a top-level "type" key — the
    // type lives in the frame's leading byte, outside the CBOR.
    @Test
    func bodyMapsAreClosedAgainstATopLevelTypeKey() throws {
        let smuggled = HouseholdCBOR.encode(.map([
            "type": .unsigned(1),
            "sig": .bytes(Data([0xCC])),
        ]))
        #expect(try M1bMeshSessionWire.bodyMapHasForbiddenTypeKey(smuggled))

        let clean = HouseholdCBOR.encode(Self.intentMap)
        #expect(try !M1bMeshSessionWire.bodyMapHasForbiddenTypeKey(clean))

        let notAMap = HouseholdCBOR.encode(.array([.unsigned(1)]))
        #expect(throws: M1bMeshSessionWireError.notAMap) {
            try M1bMeshSessionWire.bodyMapHasForbiddenTypeKey(notAMap)
        }
    }
}
