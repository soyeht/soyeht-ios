import Foundation
@testable import SoyehtCore
import Testing

// Consumer tests. The inline fixture is derived from the Swift reference's own
// verified outputs, so a green "validate" here proves the CONSUMER MACHINERY
// (JSON decode + the three caveat-sensitive checks), not cross-language
// agreement — that arrives when the independently-emitted Rust corpus file
// lands and is validated through this same machinery. The mutation tests give
// the consumer teeth: each proves it rejects a specific divergence, so a real
// corpus that disagrees with the reference fails loudly instead of passing.
@Suite("M1b tunnel-wire corpus consumer")
struct M1bTunnelWireCorpusConsumerTests {
    // A schema-faithful corpus (the exporter's published schema shape + literal examples),
    // byte values from the verified reference vectors.
    private static let fixtureJSON = """
    {
      "contract": "soyeht-mesh-session-m1b-tunnel-wire-corpus",
      "version": 1,
      "scope": "tunnel-wire framing + frame alphabet",
      "authority_status": "dev-harness",
      "format": ["lowercase hex, no 0x"],
      "framing": {
        "length_prefix": "u32-be",
        "max_frame_len": 65536,
        "zero_length_rejected": true,
        "note": "4-byte big-endian length prefix; declared length 1..=65536"
      },
      "assigned_tags_hex": ["01","10","11","12","13","14","15","16","17","18"],
      "unassigned_interior_hex":
        ["02","03","04","05","06","07","08","09","0a","0b","0c","0d","0e","0f"],
      "frames": [
        {"id":"health_with_probe","tag":"01","encoded_hex":"01deadbeef",
         "framed_hex":"0000000501deadbeef","note":"opaque probe body"},
        {"id":"open","tag":"10","encoded_hex":"10","framed_hex":"0000000110"},
        {"id":"open_persistent","tag":"18","encoded_hex":"18",
         "framed_hex":"0000000118"},
        {"id":"data","tag":"11","encoded_hex":"11deadbeef",
         "framed_hex":"0000000511deadbeef"},
        {"id":"close","tag":"12","encoded_hex":"12","framed_hex":"0000000112"},
        {"id":"error_boom","tag":"13","encoded_hex":"13626f6f6d",
         "framed_hex":"0000000513626f6f6d"},
        {"id":"window_3","tag":"14","encoded_hex":"1400000003",
         "framed_hex":"000000051400000003"},
        {"id":"resize_80_24","tag":"15","encoded_hex":"1500500018",
         "framed_hex":"000000051500500018"},
        {"id":"exit_code_0","tag":"16","encoded_hex":"160100000000",
         "framed_hex":"00000006160100000000"},
        {"id":"exit_signal_9","tag":"16","encoded_hex":"160200000009",
         "framed_hex":"00000006160200000009"}
      ],
      "target_exit_alphabet": [
        {"id":"exit_code","subtag":"01","encoded_hex":"0100000000",
         "note":"subtag 01 is not FRAME_HEALTH 01"},
        {"id":"exit_signal","subtag":"02","encoded_hex":"0200000009"},
        {"id":"exit_lost","subtag":"03","encoded_hex":"0300000000",
         "note":"value bytes ignored on decode"}
      ],
      "negatives": [
        {"id":"empty","input_hex":"","outcome":"reject","why":"no tag byte"},
        {"id":"unknown_0x00","input_hex":"00","outcome":"reject"},
        {"id":"unknown_0x19","input_hex":"19","outcome":"reject"},
        {"id":"unassigned_0x08","input_hex":"08","outcome":"reject"},
        {"id":"bad_window_short","input_hex":"14000000","outcome":"reject"},
        {"id":"bad_window_long","input_hex":"140000000000","outcome":"reject"},
        {"id":"bad_resize","input_hex":"15005000","outcome":"reject"},
        {"id":"bad_exit_len","input_hex":"16010000ff","outcome":"reject"},
        {"id":"unknown_exit_tag","input_hex":"160400000000","outcome":"reject"},
        {"id":"open_tolerates_trailing","input_hex":"10ffff","outcome":"accept",
         "why":"tag-only frame ignores trailing payload"},
        {"id":"close_tolerates_trailing","input_hex":"12ff","outcome":"accept"},
        {"id":"exit_lost_ignores_value","input_hex":"160301020304",
         "outcome":"accept","why":"Lost discards its four value bytes"}
      ]
    }
    """

    private func decodedFixture() throws -> M1bTunnelWireCorpus {
        try M1bTunnelWireCorpusConsumer.decode(Data(Self.fixtureJSON.utf8))
    }

    @Test
    func fixtureDecodesToItsSchemaShape() throws {
        let corpus = try decodedFixture()
        #expect(corpus.contract == "soyeht-mesh-session-m1b-tunnel-wire-corpus")
        #expect(corpus.version == 1)
        #expect(corpus.assignedTagsHex.count == 10)
        #expect(corpus.unassignedInteriorHex.count == 14)
        #expect(corpus.targetExitAlphabet.count == 3)
        // negatives carries BOTH outcomes — the caveat that breaks a naive
        // "all negatives must fail" consumer.
        #expect(corpus.negatives.filter { $0.outcome == .reject }.count == 9)
        #expect(corpus.negatives.filter { $0.outcome == .accept }.count == 3)
    }

    @Test
    func referenceValidatesTheWholeCorpus() throws {
        try M1bTunnelWireCorpusConsumer.validate(decodedFixture())
    }

    // ── Teeth: each mutation must be caught. ──────────────────────────────

    @Test
    func aNonCanonicalFrameEncodingIsCaught() throws {
        var corpus = try decodedFixture()
        // "10ff" decodes to .open, which re-encodes to "10" — a corpus can't
        // smuggle a non-canonical encoding past the re-encode check.
        let bad = M1bTunnelWireCorpus.Frame(
            id: "open", tag: "10", encodedHex: "10ff",
            framedHex: "0000000210ff", note: nil
        )
        corpus = Self.replacingFirstFrame(corpus, matching: "open", with: bad)
        #expect {
            try M1bTunnelWireCorpusConsumer.validate(corpus)
        } throws: { error in
            guard case M1bCorpusError.frameBodyMismatch = error else { return false }
            return true
        }
    }

    @Test
    func aWrongLengthPrefixIsCaughtEvenWhenTheBodyIsRight() throws {
        var corpus = try decodedFixture()
        // Body correct, prefix off by one — only comparing framed_hex catches it.
        let bad = M1bTunnelWireCorpus.Frame(
            id: "data", tag: "11", encodedHex: "11deadbeef",
            framedHex: "0000000411deadbeef", note: nil
        )
        corpus = Self.replacingFirstFrame(corpus, matching: "data", with: bad)
        #expect {
            try M1bTunnelWireCorpusConsumer.validate(corpus)
        } throws: { error in
            guard case M1bCorpusError.frameFramingMismatch = error else { return false }
            return true
        }
    }

    @Test
    func anAcceptMislabeledAsRejectIsCaught() throws {
        var corpus = try decodedFixture()
        // open_tolerates_trailing (10ffff) DECODES, so calling it "reject" lies.
        corpus.negatives = corpus.negatives.map { negative in
            guard negative.id == "open_tolerates_trailing" else { return negative }
            return M1bTunnelWireCorpus.Negative(
                id: negative.id, inputHex: negative.inputHex,
                outcome: .reject, why: negative.why
            )
        }
        #expect {
            try M1bTunnelWireCorpusConsumer.validate(corpus)
        } throws: { error in
            error as? M1bCorpusError == .negativeShouldReject("open_tolerates_trailing")
        }
    }

    @Test
    func anUnassignedTagClaimedAssignedIsCaught() throws {
        var corpus = try decodedFixture()
        corpus.assignedTagsHex = corpus.assignedTagsHex + ["08"]
        #expect {
            try M1bTunnelWireCorpusConsumer.validate(corpus)
        } throws: { error in
            error as? M1bCorpusError == .assignedTagRejected("08")
        }
    }

    private static func replacingFirstFrame(
        _ corpus: M1bTunnelWireCorpus,
        matching id: String,
        with replacement: M1bTunnelWireCorpus.Frame
    ) -> M1bTunnelWireCorpus {
        var copy = corpus
        if let index = copy.frames.firstIndex(where: { $0.id == id }) {
            copy.frames[index] = replacement
        }
        return copy
    }
}
