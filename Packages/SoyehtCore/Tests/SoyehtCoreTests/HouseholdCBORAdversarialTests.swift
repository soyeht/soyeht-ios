import Foundation
import Testing
@testable import SoyehtCore

// Adversarial regression suite — @maia re-verify of @fresh-arch's M1 CBOR DoS hardening.
//
// Complements HouseholdCBORTests (which already pins canonical encoding, round-trips, the
// 8-byte ARRAY count, and an 80-deep nested-ARRAY invite). This suite pins the attack
// vectors the adversarial re-attack probed that the base suite does NOT cover:
//   - the depth cap applies to MAPS (major 5), not only arrays;
//   - the single shared depth counter trips across MIXED array/map nesting;
//   - the 8-byte giant count is rejected on MAPS and the 8-byte giant length on byte/text
//     strings, BEFORE any allocation;
//   - a negative integer whose 8-byte argument exceeds Int64.max is rejected BEFORE the
//     `-1 - Int64(arg)` conversion (no overflow trap);
//   - the byte/text length boundary (== remaining decodes; +1 rejects, no over-read);
//   - the depth boundary has no over-strict off-by-one and never overflows the native stack.
//
// All inputs are either raw header bytes (no encoder recursion) or built with a `for` loop
// (no encoder recursion in construction); nesting depths kept well above the 64 cap but
// modest enough that the test-side `HouseholdCBOR.encode` does not itself deep-recurse.
@Suite("HouseholdCBOR adversarial (DoS hardening)")
struct HouseholdCBORAdversarialTests {
    @Test func decodeRejectsDeeplyNestedMapsWithoutCrashing() {
        // Depth-cap MUST apply to maps (major type 5), not only arrays.
        var value: HouseholdCBORValue = .unsigned(0)
        for _ in 0..<200 { value = .map(["k": value]) }
        let encoded = HouseholdCBOR.encode(value)
        #expect(throws: HouseholdCBORError.nestingTooDeep) {
            try HouseholdCBOR.decode(encoded)
        }
    }

    @Test func decodeRejectsMixedArrayMapAlternatingNestingWithoutCrashing() {
        // A single shared depth counter must trip across alternating array/map frames —
        // a per-type counter would be defeated by alternation.
        var value: HouseholdCBORValue = .unsigned(0)
        for i in 0..<200 { value = (i % 2 == 0) ? .array([value]) : .map(["k": value]) }
        let encoded = HouseholdCBOR.encode(value)
        #expect(throws: HouseholdCBORError.nestingTooDeep) {
            try HouseholdCBOR.decode(encoded)
        }
    }

    @Test func decodeRejectsEightByteGiantMapCountBeforeAllocating() {
        // 0xBB = major 5 (map), additional 27 (8-byte count) + 0xFFFF...FF.
        // Must be rejected by the bounded element-count check (maps need >= 2 bytes/entry)
        // BEFORE Int(count) or any loop.
        let hugeMapHeader = Data([0xBB, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: HouseholdCBORError.invalidData) {
            try HouseholdCBOR.decode(hugeMapHeader)
        }
    }

    @Test func decodeRejectsEightByteGiantByteAndTextLengthBeforeAllocating() {
        // 0x5B = bytes (major 2) + 8-byte length; 0x7B = text (major 3) + 8-byte length.
        // The bounded-length check must reject BEFORE Int(length) (no overflow) and BEFORE
        // any Data allocation.
        for header in [
            Data([0x5B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            Data([0x7B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ] {
            #expect(throws: HouseholdCBORError.invalidData) {
                try HouseholdCBOR.decode(header)
            }
        }
    }

    @Test func decodeRejectsNegativeIntegerArgumentOverflowingInt64() {
        // 0x3B = major 1 (negative) + 8-byte argument. arg = UInt64.max would trap on
        // `-1 - Int64(arg)` if unguarded.
        #expect(throws: HouseholdCBORError.invalidData) {
            try HouseholdCBOR.decode(Data([0x3B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        }
        // Boundary: arg == Int64.max + 1 (0x8000...0) is the smallest unrepresentable arg.
        #expect(throws: HouseholdCBORError.invalidData) {
            try HouseholdCBOR.decode(Data([0x3B, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        }
        // Sanity (no over-strict guard): arg == Int64.max (0x7FFF...F) IS representable and
        // must decode to .negative(-1 - Int64.max) == .negative(Int64.min).
        let maxValid = Data([0x3B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect((try? HouseholdCBOR.decode(maxValid)) == .negative(Int64.min))
    }

    @Test func decodeByteAndTextLengthExactVsOneOverBoundary() {
        // bytes(3) with exactly 3 payload bytes decodes; bytes(4) with only 3 bytes rejects.
        #expect((try? HouseholdCBOR.decode(Data([0x43, 0xAA, 0xBB, 0xCC]))) == .bytes(Data([0xAA, 0xBB, 0xCC])))
        #expect(throws: HouseholdCBORError.invalidData) {
            try HouseholdCBOR.decode(Data([0x44, 0xAA, 0xBB, 0xCC]))
        }
        // text(2) "hi" decodes; text(3) with only 2 bytes rejects (no over-read).
        #expect((try? HouseholdCBOR.decode(Data([0x62, 0x68, 0x69]))) == .text("hi"))
        #expect(throws: HouseholdCBORError.invalidData) {
            try HouseholdCBOR.decode(Data([0x63, 0x68, 0x69]))
        }
    }

    @Test func decodeDepthBoundaryAllowsModerateNestingButRejectsExtreme() {
        func nestedArrays(_ levels: Int) -> Data {
            var value: HouseholdCBORValue = .unsigned(0)
            for _ in 0..<levels { value = .array([value]) }
            return HouseholdCBOR.encode(value)
        }
        // Well under the 64 cap: must decode (guards against an over-strict off-by-one that
        // would reject legitimate moderately-nested payloads).
        #expect((try? HouseholdCBOR.decode(nestedArrays(50))) != nil)
        // Well over the cap: must throw the depth guard, never a native stack overflow.
        #expect(throws: HouseholdCBORError.nestingTooDeep) {
            try HouseholdCBOR.decode(nestedArrays(200))
        }
    }
}
