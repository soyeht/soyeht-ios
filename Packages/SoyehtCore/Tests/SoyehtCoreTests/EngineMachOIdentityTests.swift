import Foundation
import XCTest
@testable import SoyehtCore

final class EngineMachOIdentityTests: XCTestCase {
    private func words(_ values: [UInt32]) -> Data {
        Data(values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
    }

    private var command: Data { words([0x1b, 24]) + Data(0..<16) }
    private var header: Data { words([0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0]) }

    func testReadsOnlyTheSingleThinExecutableUUID() throws {
        let image = header + command
        XCTAssertEqual(EngineMachOIdentity.imageUUID(in: image), "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(EngineMachOIdentity.imageUUID(in: image + Data("signature".utf8)),
                       EngineMachOIdentity.imageUUID(in: image))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try image.write(to: file)
        XCTAssertEqual(try EngineMachOIdentity.imageUUID(at: file), EngineMachOIdentity.imageUUID(in: image))
    }

    func testRejectsFatWrongArchitectureAndDuplicateUUID() {
        XCTAssertNil(EngineMachOIdentity.imageUUID(in: words([0xbebafeca, 2, 0, 2, 1, 24, 0, 0]) + command))
        XCTAssertNil(EngineMachOIdentity.imageUUID(in: words([0xfeedfacf, 0x01000007, 0, 2, 1, 24, 0, 0]) + command))
        XCTAssertNil(EngineMachOIdentity.imageUUID(in: words([0xfeedfacf, 0x0100000c, 0, 2, 2, 48, 0, 0]) + command + command))
    }

    func testRejectsTruncationMissingUUIDAndInvalidBounds() {
        for count in 0..<(header + command).count {
            XCTAssertNil(EngineMachOIdentity.imageUUID(in: (header + command).prefix(count)), "accepted truncation at \(count)")
        }
        XCTAssertNil(EngineMachOIdentity.imageUUID(in: header + words([0x1b, 0]) + Data(repeating: 0, count: 16)))
        XCTAssertNil(EngineMachOIdentity.imageUUID(in: header + words([0x10, 24]) + Data(repeating: 0, count: 16)))
        XCTAssertNil(EngineMachOIdentity.imageUUID(in: words([0xfeedfacf, 0x0100000c, 0, 2, 1, 0xfffffff0, 0, 0])))
    }
}
