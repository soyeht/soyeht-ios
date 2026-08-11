import Foundation
@testable import SoyehtCore
import Testing

// M1b Swift-side wire vectors. The hex expectations below are hand-derived
// from theyos `tunnel-wire-rs` (`TunnelFrame::encode`/`decode`,
// `NonblockingFrameReader::poll_read`) and pin the Swift reference
// implementation to fixed bytes so the upcoming Rust-emitted vector corpus
// has a same-shaped counterpart to compare against. Positive vectors first,
// then the decoder-asymmetry pins, then the negatives the plan names.
@Suite("M1b tunnel-wire Swift reference vectors")
struct M1bTunnelWireReferenceTests {
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(fromHex hex: String) -> Data {
        var out = Data()
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            out.append(UInt8(String([high, low]), radix: 16)!)
        }
        return out
    }

    private static let positiveVectors: [(frame: M1bTunnelWireFrame, frameHex: String)] = [
        (.health(Data([0xAA, 0xBB])), "01aabb"),
        (.open, "10"),
        (.openPersistent, "18"),
        (.data(Data([0xDE, 0xAD, 0xBE, 0xEF])), "11deadbeef"),
        (.close, "12"),
        (.error("boom"), "13626f6f6d"),
        (.error(""), "13"),
        (.window(3), "1400000003"),
        (.window(UInt32.max), "14ffffffff"),
        (.resize(cols: 80, rows: 24), "1500500018"),
        (.exit(.code(0)), "160100000000"),
        (.exit(.code(-1)), "1601ffffffff"),
        (.exit(.signal(9)), "160200000009"),
        (.exit(.lost), "160300000000"),
        (.networkSettings(Data([0xA0])), "17a0"),
    ]

    @Test
    func everyFrameKindEncodesToItsPinnedBytesAndRoundTrips() throws {
        for vector in Self.positiveVectors {
            let encoded = vector.frame.encode()
            #expect(Self.hex(encoded) == vector.frameHex)
            #expect(try M1bTunnelWireFrame.decode(encoded) == vector.frame)

            let framed = try M1bLengthPrefixedFraming.encode(vector.frame)
            let expectedPrefix = String(format: "%08x", encoded.count)
            #expect(Self.hex(framed) == expectedPrefix + vector.frameHex)
            #expect(try M1bLengthPrefixedFraming.decodeStream(framed) == [vector.frame])
        }
    }

    @Test
    func consecutiveFramesDecodeFromOneStream() throws {
        let stream = try M1bLengthPrefixedFraming.encode(.open)
            + M1bLengthPrefixedFraming.encode(.data(Data([0x01])))
            + M1bLengthPrefixedFraming.encode(.close)
        let frames = try M1bLengthPrefixedFraming.decodeStream(stream)
        #expect(frames == [.open, .data(Data([0x01])), .close])
    }

    // The Rust decoder matches tag-only frames without inspecting payload:
    // `[0x10, 0xff]` decodes to Open, and re-encoding yields `[0x10]`. Pinned
    // so tightening either side becomes a visible cross-language break.
    @Test
    func tagOnlyFramesTolerateTrailingPayloadWithoutRoundTripping() throws {
        for (tagged, frame) in [
            ("10ff", M1bTunnelWireFrame.open),
            ("18ff", .openPersistent),
            ("12ff", .close),
        ] {
            let decoded = try M1bTunnelWireFrame.decode(Self.data(fromHex: tagged))
            #expect(decoded == frame)
            #expect(Self.hex(decoded.encode()) != tagged)
        }
    }

    // Same asymmetry for Lost: the Rust decoder computes the value bytes and
    // discards them, so any 4 value bytes after tag 0x03 decode to `.lost`,
    // which re-encodes with zeroed value bytes.
    @Test
    func exitLostIgnoresValueBytesOnDecode() throws {
        let lossy = Self.data(fromHex: "160301020304")
        #expect(try M1bTunnelWireFrame.decode(lossy) == .exit(.lost))
        #expect(Self.hex(M1bTunnelWireFrame.exit(.lost).encode()) == "160300000000")
    }

    @Test
    func errorFrameAppliesLossyUTF8Substitution() throws {
        // 0xFF is never valid UTF-8; both sides substitute U+FFFD.
        let decoded = try M1bTunnelWireFrame.decode(Self.data(fromHex: "1361ff62"))
        #expect(decoded == .error("a\u{FFFD}b"))
    }

    // The assigned tag set is NOT a contiguous range: 0x01 then 0x10–0x18,
    // with 0x02–0x0f unassigned. A decoder derived from "0x01 through 0x18"
    // would accept the fourteen interior values 0x02–0x0f that do not exist,
    // and a positives-only corpus would never catch it — so EVERY unassigned
    // interior tag is pinned as an explicit negative (the loop runs all 14):
    // endpoint sampling cannot notice a decoder growing an eleventh frame
    // kind in the middle.
    @Test
    func everyUnassignedInteriorTagIsRejected() {
        for tag in UInt8(0x02)...0x0f {
            #expect(throws: M1bWireDecodeError.unknownFrameKind(tag)) {
                try M1bTunnelWireFrame.decode(Data([tag]))
            }
        }
    }

    @Test
    func malformedFrameBodiesAreRejected() {
        let cases: [(bodyHex: String, expected: M1bWireDecodeError)] = [
            ("", .emptyFrame),
            ("00", .unknownFrameKind(0x00)),
            ("19", .unknownFrameKind(0x19)),
            ("14000000", .badWindowFrame),
            ("140000000000", .badWindowFrame),
            ("15005000", .badResizeFrame),
            ("16010000ff", .badExitFrame),
            ("16010000ffffff", .badExitFrame),
            ("160400000000", .unknownExitTag(0x04)),
        ]
        for testCase in cases {
            #expect(throws: testCase.expected) {
                try M1bTunnelWireFrame.decode(Self.data(fromHex: testCase.bodyHex))
            }
        }
    }

    @Test
    func lengthPrefixBoundsMatchTheRustReader() throws {
        // Zero-length is rejected before any body read.
        #expect(throws: M1bWireDecodeError.zeroLengthPrefix) {
            try M1bLengthPrefixedFraming.decodeStream(Self.data(fromHex: "00000000"))
        }

        // 64 KiB exactly is the largest accepted declared length…
        let maxBody = Data([M1bTunnelWireFrame.frameData])
            + Data(count: M1bTunnelWireFrame.maxFrameLength - 1)
        var framedMax = Data([0x00, 0x01, 0x00, 0x00])
        framedMax.append(maxBody)
        let decoded = try M1bLengthPrefixedFraming.decodeStream(framedMax)
        #expect(decoded == [.data(Data(count: M1bTunnelWireFrame.maxFrameLength - 1))])

        // …and one past it is rejected without waiting for the body.
        #expect(throws: M1bWireDecodeError.oversizedLengthPrefix(65_537)) {
            try M1bLengthPrefixedFraming.decodeStream(Self.data(fromHex: "00010001"))
        }
    }

    // The WRITER bound, distinct from the reader's: Rust's
    // `NonblockingFrameWriter::enqueue` refuses a total encoded body (tag
    // included) over 64 KiB, so the Swift encoder must refuse it too rather
    // than emit a frame every conformant reader rejects.
    @Test
    func writerRefusesOversizedBodiesAtTheRustEnqueueBound() throws {
        let atCap = M1bTunnelWireFrame.data(
            Data(count: M1bTunnelWireFrame.maxFrameLength - 1)
        )
        #expect(
            try M1bLengthPrefixedFraming.encode(atCap).count
                == 4 + M1bTunnelWireFrame.maxFrameLength
        )
        let overCap = M1bTunnelWireFrame.data(
            Data(count: M1bTunnelWireFrame.maxFrameLength)
        )
        #expect(
            throws: M1bWireDecodeError.oversizedFrameBody(
                M1bTunnelWireFrame.maxFrameLength + 1
            )
        ) {
            try M1bLengthPrefixedFraming.encode(overCap)
        }
    }

    @Test
    func streamsEndingMidFrameAreRejected() {
        // Mid-prefix and mid-payload, mirroring the reader's EOF-as-fatal rule.
        for streamHex in ["000000", "0000000210"] {
            #expect(throws: M1bWireDecodeError.truncatedStream) {
                try M1bLengthPrefixedFraming.decodeStream(Self.data(fromHex: streamHex))
            }
        }
    }

    // Canonical-CBOR spot vectors for the production Swift codec the M1b
    // corpus will exercise: RFC 8949 deterministic ordering compares the
    // *encoded* key bytes, so shorter keys sort before longer ones regardless
    // of content ("a", "b", then "aa"), and scalars must take shortest form.
    // The Rust side (`mesh-session-core-rs/src/cbor.rs`,
    // `tunnel-wire-rs/src/canonical.rs`) applies the same rule via ciborium.
    @Test
    func householdCBORMatchesCanonicalOrderingAndShortestFormVectors() throws {
        let map = HouseholdCBORValue.map([
            "b": .unsigned(1),
            "a": .unsigned(2),
            "aa": .unsigned(3),
        ])
        #expect(Self.hex(HouseholdCBOR.encode(map)) == "a3616102616201626161" + "03")

        let scalars: [(UInt64, String)] = [
            (23, "17"),
            (24, "1818"),
            (255, "18ff"),
            (256, "190100"),
            (65_536, "1a00010000"),
            (UInt64(UInt32.max) + 1, "1b0000000100000000"),
        ]
        for (value, expectedHex) in scalars {
            #expect(Self.hex(HouseholdCBOR.encode(.unsigned(value))) == expectedHex)
        }
    }

    // Divergence pin, not an endorsement — and scoped to the codec it is
    // true of: `mesh-session-core-rs/src/cbor.rs` (the hardened B-SESSAO
    // codec) rejects null at every depth, while `tunnel-wire-rs/src/
    // canonical.rs` accepts `Value::Null`. HouseholdCBOR emits null (0xf6),
    // so a Swift encoder that lets null reach a MESH-SESSION preimage would
    // produce bytes that side refuses; the corpus must include this
    // negative; until then this records the asymmetry where it can fail
    // loudly.
    @Test
    func householdCBORStillEmitsNullWhichMeshSessionCBORRejects() {
        #expect(Self.hex(HouseholdCBOR.encode(.null)) == "f6")
    }
}
