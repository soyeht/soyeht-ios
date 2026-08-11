import Foundation

// Consumer for the Rust-emitted M1b tunnel-wire corpus
// (theyos admin/contracts/mesh-session/v1/m1b_tunnel_wire_corpus_v1.json,
// emitted by an independent Rust exporter). Decodes the corpus JSON and
// validates it against the Swift reference in M1bTunnelWireReference.swift.
// The schema is pinned independently of the corpus file, so a consumer can be
// written against it before the corpus exists; cross-language validation is
// immediate once the corpus is pushed.
//
// Three schema subtleties are load-bearing and handled explicitly, because
// they do not read off the field names (the exporter's caveats):
//
//  1. `negatives` is NOT all negatives — each entry carries an `outcome` of
//     "reject" or "accept". The three "accept" cases are the decode
//     asymmetries (open/close tolerate trailing bytes, TargetExit::Lost
//     discards its four value bytes). Filtering "it's under negatives, so it
//     must fail" would wrongly reject three inputs the Rust decoder accepts.
//  2. `encoded_hex` (frame body) and `framed_hex` (body with the u32-BE length
//     prefix) are distinct and both checked — comparing only the body would
//     let an endianness or width error in the prefix pass.
//  3. `target_exit_alphabet` decodes through M1bTargetExitReference, a type
//     separate from the frame tags: subtag 0x01 and FRAME_HEALTH 0x01 are the
//     same byte under different authority.
//
// `network_settings` (0x17) is deliberately absent: NetworkSettingsBody has a
// pub(crate) constructor, so no integration test can build one — the same wall
// on both sides. The consumer applies NO 0x17 body validation; doing so would
// make Swift stricter than Rust exactly where Rust delegates to the product.

struct M1bTunnelWireCorpus: Decodable {
    struct Framing: Decodable {
        let lengthPrefix: String
        let maxFrameLen: Int
        let zeroLengthRejected: Bool
        let note: String?

        enum CodingKeys: String, CodingKey {
            case lengthPrefix = "length_prefix"
            case maxFrameLen = "max_frame_len"
            case zeroLengthRejected = "zero_length_rejected"
            case note
        }
    }

    struct Frame: Decodable {
        let id: String
        let tag: String
        let encodedHex: String
        let framedHex: String
        let note: String?

        enum CodingKeys: String, CodingKey {
            case id, tag, note
            case encodedHex = "encoded_hex"
            case framedHex = "framed_hex"
        }
    }

    struct ExitEntry: Decodable {
        let id: String
        let subtag: String
        let encodedHex: String
        let note: String?

        enum CodingKeys: String, CodingKey {
            case id, subtag, note
            case encodedHex = "encoded_hex"
        }
    }

    enum NegativeOutcome: String, Decodable {
        case reject
        case accept
    }

    struct Negative: Decodable {
        let id: String
        let inputHex: String
        let outcome: NegativeOutcome
        let why: String?

        enum CodingKeys: String, CodingKey {
            case id, outcome, why
            case inputHex = "input_hex"
        }
    }

    let contract: String
    let version: Int
    let framing: Framing
    var assignedTagsHex: [String]
    var unassignedInteriorHex: [String]
    var frames: [Frame]
    var targetExitAlphabet: [ExitEntry]
    var negatives: [Negative]

    enum CodingKeys: String, CodingKey {
        case contract, version, framing, frames, negatives
        case assignedTagsHex = "assigned_tags_hex"
        case unassignedInteriorHex = "unassigned_interior_hex"
        case targetExitAlphabet = "target_exit_alphabet"
    }
}

enum M1bCorpusError: Error, Equatable {
    case wrongContract(String)
    case unsupportedVersion(Int)
    case framingMismatch(String)
    case oddHex(String)
    case assignedTagRejected(String)
    case unassignedTagAccepted(String)
    case frameBodyMismatch(id: String, expected: String, actual: String)
    case frameFramingMismatch(id: String, expected: String, actual: String)
    case exitEntryMismatch(id: String, expected: String, actual: String)
    case negativeShouldReject(String)
    case negativeShouldAccept(String)
}

enum M1bTunnelWireCorpusConsumer {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(fromHex hexString: String) throws -> Data {
        guard hexString.count % 2 == 0 else { throw M1bCorpusError.oddHex(hexString) }
        var out = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                throw M1bCorpusError.oddHex(hexString)
            }
            out.append(byte)
            index = next
        }
        return out
    }

    static func decode(_ json: Data) throws -> M1bTunnelWireCorpus {
        try JSONDecoder().decode(M1bTunnelWireCorpus.self, from: json)
    }

    /// Validate every section against the Swift reference. Throws on the first
    /// disagreement so a divergence names its exact corpus id.
    static func validate(_ corpus: M1bTunnelWireCorpus) throws {
        guard corpus.contract == "soyeht-mesh-session-m1b-tunnel-wire-corpus" else {
            throw M1bCorpusError.wrongContract(corpus.contract)
        }
        guard corpus.version == 1 else {
            throw M1bCorpusError.unsupportedVersion(corpus.version)
        }
        guard corpus.framing.lengthPrefix == "u32-be" else {
            throw M1bCorpusError.framingMismatch(corpus.framing.lengthPrefix)
        }
        guard corpus.framing.maxFrameLen == M1bTunnelWireFrame.maxFrameLength else {
            throw M1bCorpusError.framingMismatch("max_frame_len=\(corpus.framing.maxFrameLen)")
        }
        guard corpus.framing.zeroLengthRejected else {
            throw M1bCorpusError.framingMismatch("zero_length_rejected=false")
        }

        // Assigned tags are the bare tag BYTES (a tag inventory), so a
        // length-bearing tag like window/resize/exit fails to decode on its
        // own — that is "assigned but needs a payload", NOT "unknown kind".
        // The only disqualifying outcome is unknownFrameKind.
        for tagHex in corpus.assignedTagsHex {
            let bytes = try data(fromHex: tagHex)
            do {
                _ = try M1bTunnelWireFrame.decode(bytes)
            } catch let error as M1bWireDecodeError {
                if case .unknownFrameKind = error {
                    throw M1bCorpusError.assignedTagRejected(tagHex)
                }
                // Any other decode error means the tag IS recognized — fine.
            }
        }

        // Unassigned interior tags must be rejected SPECIFICALLY as unknown
        // kind — not merely fail for some other reason.
        for tagHex in corpus.unassignedInteriorHex {
            let bytes = try data(fromHex: tagHex)
            var rejectedAsUnknown = false
            do {
                _ = try M1bTunnelWireFrame.decode(bytes)
            } catch let error as M1bWireDecodeError {
                if case .unknownFrameKind = error { rejectedAsUnknown = true }
            }
            if !rejectedAsUnknown {
                throw M1bCorpusError.unassignedTagAccepted(tagHex)
            }
        }

        // Each frame: the decoded frame must re-encode to encoded_hex, AND its
        // wire form must equal framed_hex — both, per caveat 2.
        for frame in corpus.frames {
            let decoded = try M1bTunnelWireFrame.decode(try data(fromHex: frame.encodedHex))
            let reEncoded = hex(decoded.encode())
            guard reEncoded == frame.encodedHex else {
                throw M1bCorpusError.frameBodyMismatch(
                    id: frame.id, expected: frame.encodedHex, actual: reEncoded
                )
            }
            let framed = hex(try M1bLengthPrefixedFraming.encode(decoded))
            guard framed == frame.framedHex else {
                throw M1bCorpusError.frameFramingMismatch(
                    id: frame.id, expected: frame.framedHex, actual: framed
                )
            }
        }

        // Exit alphabet decodes through the SEPARATE TargetExit type.
        for entry in corpus.targetExitAlphabet {
            let exit = try M1bTargetExitReference.decode(try data(fromHex: entry.encodedHex))
            let reEncoded = hex(exit.encode())
            guard reEncoded == entry.encodedHex else {
                throw M1bCorpusError.exitEntryMismatch(
                    id: entry.id, expected: entry.encodedHex, actual: reEncoded
                )
            }
        }

        // Negatives split on outcome: reject must throw, accept must decode.
        for negative in corpus.negatives {
            let bytes = try data(fromHex: negative.inputHex)
            let decoded = try? M1bTunnelWireFrame.decode(bytes)
            switch negative.outcome {
            case .reject:
                if decoded != nil { throw M1bCorpusError.negativeShouldReject(negative.id) }
            case .accept:
                if decoded == nil { throw M1bCorpusError.negativeShouldAccept(negative.id) }
            }
        }
    }
}
