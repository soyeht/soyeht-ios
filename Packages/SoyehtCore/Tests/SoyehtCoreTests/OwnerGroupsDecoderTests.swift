import XCTest
@testable import SoyehtCore

/// Slice 3b read model: `OwnerGroupsDecoder` decodes the planned
/// `GET /api/v1/claw-share/groups` canonical-CBOR body into the SHARED APPS
/// display model. Built against the agreed wire shape (the server endpoint is a
/// later @vivian slice); lab-tested here against a constructed sample + the
/// strict error paths.
final class OwnerGroupsDecoderTests: XCTestCase {
    private func sampleBody(
        version: UInt64 = 1,
        deviceCount: HouseholdCBORValue = .unsigned(2)
    ) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(version),
            "groups": .array([
                .map([
                    "group_id": .text("g_alpha"),
                    "name": .text("Family"),
                    "members": .array([
                        .map([
                            "member_id": .text("g_dani"),
                            "label": .text("Dani"),
                            "device_count": deviceCount,
                        ]),
                    ]),
                    "granted_claws": .array([.text("claw_x"), .text("claw_y")]),
                ]),
            ]),
            "published_claws": .array([.text("claw_pub")]),
        ]))
    }

    func testDecodesSnapshot() throws {
        let snap = try OwnerGroupsDecoder.decode(sampleBody())
        XCTAssertEqual(snap.publishedClaws, ["claw_pub"])
        XCTAssertEqual(snap.groups.count, 1)
        let g = snap.groups[0]
        XCTAssertEqual(g.groupID, "g_alpha")
        XCTAssertEqual(g.name, "Family")
        XCTAssertEqual(g.grantedClaws, ["claw_x", "claw_y"])
        XCTAssertEqual(g.members, [OwnerGroupMember(memberID: "g_dani", label: "Dani", deviceCount: 2)])
    }

    func testRejectsWrongVersion() {
        XCTAssertThrowsError(try OwnerGroupsDecoder.decode(sampleBody(version: 2))) { error in
            XCTAssertEqual(error as? OwnerGroupsDecodeError, .unsupportedVersion)
        }
    }

    func testRejectsWrongFieldType() {
        // device_count as text instead of unsigned ⇒ wrongType.
        XCTAssertThrowsError(try OwnerGroupsDecoder.decode(sampleBody(deviceCount: .text("nope")))) { error in
            XCTAssertEqual(error as? OwnerGroupsDecodeError, .wrongType("device_count"))
        }
    }

    func testRejectsMissingField() {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "groups": .array([
                .map([
                    "group_id": .text("g_alpha"),
                    // "name" missing
                    "members": .array([]),
                    "granted_claws": .array([]),
                ]),
            ]),
            "published_claws": .array([]),
        ]))
        XCTAssertThrowsError(try OwnerGroupsDecoder.decode(body)) { error in
            XCTAssertEqual(error as? OwnerGroupsDecodeError, .missingField("name"))
        }
    }

    func testRejectsNonMap() {
        let body = HouseholdCBOR.encode(.array([.text("nope")]))
        XCTAssertThrowsError(try OwnerGroupsDecoder.decode(body)) { error in
            XCTAssertEqual(error as? OwnerGroupsDecodeError, .notMap)
        }
    }

    func testEmptyGroups() throws {
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "groups": .array([]),
            "published_claws": .array([]),
        ]))
        let snap = try OwnerGroupsDecoder.decode(body)
        XCTAssertTrue(snap.groups.isEmpty)
        XCTAssertTrue(snap.publishedClaws.isEmpty)
    }
}
