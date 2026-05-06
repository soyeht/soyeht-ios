import Testing
import Foundation
@testable import SoyehtCore

/// Pins the bounds applied to untrusted `resize` / `input` frames on the
/// pairing protocol. These caps live in `SoyehtCore` so the iOS sender and
/// the Mac receivers stay aligned; if the limits ever drift, both sides
/// must move together.
@Suite struct PairingPayloadLimitsTests {

    @Test func columnRangeRejectsZeroAndNegative() {
        #expect(!PairingPayloadLimits.columnRange.contains(0))
        #expect(!PairingPayloadLimits.columnRange.contains(-1))
        #expect(!PairingPayloadLimits.columnRange.contains(Int.min))
    }

    @Test func columnRangeRejectsAboveCap() {
        #expect(!PairingPayloadLimits.columnRange.contains(4097))
        #expect(!PairingPayloadLimits.columnRange.contains(Int.max))
    }

    @Test func columnRangeAcceptsRealisticValues() {
        // Common terminal widths.
        for cols in [1, 80, 132, 200, 1000, 4096] {
            #expect(PairingPayloadLimits.columnRange.contains(cols), "\(cols) should be a valid column count")
        }
    }

    @Test func rowRangeRejectsZeroAndNegative() {
        #expect(!PairingPayloadLimits.rowRange.contains(0))
        #expect(!PairingPayloadLimits.rowRange.contains(-1))
        #expect(!PairingPayloadLimits.rowRange.contains(Int.min))
    }

    @Test func rowRangeRejectsAboveCap() {
        #expect(!PairingPayloadLimits.rowRange.contains(4097))
        #expect(!PairingPayloadLimits.rowRange.contains(Int.max))
    }

    @Test func rowRangeAcceptsRealisticValues() {
        for rows in [1, 24, 50, 80, 200, 4096] {
            #expect(PairingPayloadLimits.rowRange.contains(rows), "\(rows) should be a valid row count")
        }
    }

    @Test func inputMaxBytesIsOneMebibyte() {
        // 1 MiB — generous enough for a real clipboard paste, tight enough
        // that an attacker cannot allocate gigabytes per frame.
        #expect(PairingPayloadLimits.inputMaxBytes == 1_048_576)
    }

    @Test func inputMaxBytesAccommodatesTypicalPaste() {
        // A 64 KiB paste (a long log excerpt, a JSON snippet) must fit.
        let typicalPaste = String(repeating: "x", count: 64 * 1024)
        #expect(typicalPaste.utf8.count <= PairingPayloadLimits.inputMaxBytes)
    }

    @Test func inputMaxBytesRejectsAdversarialPayload() {
        // The bound is a byte count, not a character count. A multi-byte
        // UTF-8 sequence multiplied above the cap must trip the limit.
        let oversized = String(repeating: "🛡", count: PairingPayloadLimits.inputMaxBytes / 2)
        #expect(oversized.utf8.count > PairingPayloadLimits.inputMaxBytes)
    }
}
