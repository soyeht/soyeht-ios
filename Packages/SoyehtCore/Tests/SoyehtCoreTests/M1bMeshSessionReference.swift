import CryptoKit
import Foundation
@testable import SoyehtCore

// M1b slice 2 (docs/mesh-plan.md, theyos): the Swift half of the
// mesh-session wire contract — constants and composition rules from theyos
// `mesh-session-core-rs` (`auth_frames.rs`, `intent.rs`, `wire.rs`,
// `cbor.rs`). Like the slice-1 tunnel-wire reference, this lives in the
// test target: production Swift gains the surface with M4, and these
// vectors become that layer's acceptance tests.
//
// The three frozen composition formulas (B-SESSAO v6 §3 / D9 §2):
//
//   signed_preimage = type_byte || canonical_cbor(unsigned_body)
//   frame_digest    = SHA256(type_byte || canonical_cbor(full_frame))
//   intent_digest   = SHA256(ASCII(domain) || canonical_cbor(full_intent))
//
// where `unsigned_body` is the full frame's canonical CBOR with its single
// top-level "sig" entry removed — which is precisely what the production
// `HouseholdCBOR.canonicalMapWithoutKey(_:removing:)` computes, so that
// production codec is deliberately on the hot path here instead of a
// test-local reimplementation: byte disagreement with ciborium's
// canonicalization must fail these vectors, not hide behind a shadow codec.
//
// Note the deliberate asymmetry between the two digests: the frame digest
// domain-separates with the leading type byte, the intent digest with the
// full ASCII domain string and NO type byte — both are computed over the
// canonical bytes INCLUDING `sig`, so intents/frames differing only in
// signature digest differently.

enum M1bMeshSessionWire {
    // Auth-frame type bytes (mesh-session-core-rs/src/auth_frames.rs).
    static let typeProofR: UInt8 = 0x01
    static let typeProofI: UInt8 = 0x02
    static let typeFinalConfirm: UInt8 = 0x03
    static let typeActivate: UInt8 = 0x04
    static let typeActivateAck: UInt8 = 0x05
    // Intent record and the reserved capability byte (intent.rs).
    static let intentTypeByte: UInt8 = 0x06
    static let capabilityTypeByteReserved: UInt8 = 0x07

    static let protocolVersion: UInt64 = 1
    static let domain = "soyeht/mesh-session/v1"
    static let intentDomain = "soyeht/mesh-connection-intent/v1"
    static let intentVersion: UInt64 = 1
    static let roleResponder = "responder"
    static let roleInitiator = "initiator"
    static let kindFinalConfirm = "final-confirm"
    static let kindActivate = "activate"
    static let kindActivateAck = "activate-ack"

    // Record limits (wire.rs). MAX_PLAINTEXT_LEN subtracts the Poly1305
    // tag from the noise record; MAX_CBOR_BODY_LEN additionally subtracts
    // the leading type byte.
    static let maxNoiseHandshakeMessageLen: UInt32 = 65_535
    static let maxNoiseRecordLen: UInt32 = 65_535
    static let poly1305TagLen: UInt32 = 16
    static let maxPlaintextLen: UInt32 = maxNoiseRecordLen - poly1305TagLen
    static let typeByteLen: UInt32 = 1
    static let maxCBORBodyLen: UInt32 = maxPlaintextLen - typeByteLen

    static let connectionIntentDigestLength = 32

    /// `signed_preimage = type_byte || canonical_cbor(unsigned_body)` —
    /// the unsigned body is the full frame minus its top-level `"sig"`.
    ///
    /// The Rust side (`cbor::unsigned_preimage_body`) FAILS when the value
    /// does not carry exactly one `sig` entry; `canonicalMapWithoutKey`
    /// alone would silently no-op on a sig-less map, so the reference
    /// enforces the Rust rule explicitly. (Top-level map keys are unique
    /// after canonical decoding, so present == exactly one.)
    static func signingPreimage(typeByte: UInt8, fullFrame: Data) throws -> Data {
        guard case .map(let entries) = try HouseholdCBOR.decode(fullFrame) else {
            throw M1bMeshSessionWireError.notAMap
        }
        guard entries.keys.contains("sig") else {
            throw M1bMeshSessionWireError.missingSigField
        }
        let unsigned = try HouseholdCBOR.canonicalMapWithoutKey(fullFrame, removing: "sig")
        return Data([typeByte]) + unsigned
    }

    /// `frame_digest = SHA256(type_byte || canonical_cbor(full_frame))`.
    static func frameDigest(typeByte: UInt8, fullFrame: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data([typeByte]))
        hasher.update(data: fullFrame)
        return Data(hasher.finalize())
    }

    /// `intent_digest = SHA256(ASCII(domain) || I_full)` — no type byte;
    /// the domain string itself is the separation tag.
    static func intentDigest(fullIntent: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(intentDomain.utf8))
        hasher.update(data: fullIntent)
        return Data(hasher.finalize())
    }

    /// v6 §3: the body map is closed against a top-level `"type"` key,
    /// because the type lives outside the CBOR in the frame's leading byte.
    static func bodyMapHasForbiddenTypeKey(_ body: Data) throws -> Bool {
        guard case .map(let entries) = try HouseholdCBOR.decode(body) else {
            throw M1bMeshSessionWireError.notAMap
        }
        return entries.keys.contains("type")
    }
}

enum M1bMeshSessionWireError: Error, Equatable {
    case notAMap
    case missingSigField
}
