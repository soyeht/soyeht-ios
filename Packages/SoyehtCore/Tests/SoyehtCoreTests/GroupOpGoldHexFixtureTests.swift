import XCTest
@testable import SoyehtCore

/// Cross-language byte-tight fixture for the `/group-op` encoder — pins the Swift
/// `GroupOpRequest.encode` output against @vivian's Rust-generated SSOT gold hex
/// (`product-a-group-op-fixtures.md`, commit fa5be1c). Same recipe as the
/// relay-offer lockstep: identical canonical inputs ⇒ identical canonical-CBOR
/// bytes both sides. This seals slice 1 (the encoder).
final class GroupOpGoldHexFixtureTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    private func bytes(_ h: String) -> Data {
        var data = Data(capacity: h.count / 2)
        var index = h.startIndex
        while index < h.endIndex {
            let next = h.index(index, offsetBy: 2)
            data.append(UInt8(h[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// `member_id = derive_member_id(member_pub)` = 54 chars ("g_" + 52 base32).
    /// NOTE: the fixture doc's *canonical-inputs text* lists this with a stray
    /// trailing "j" (55 chars), but the Rust-generated GOLD HEX (the SSOT) encodes
    /// 54 — that is authoritative (derive_member_id of the `[0x55;32]` scalar).
    /// Flagged to @vivian to fix the doc prose.
    private let memberID = "g_leqzmohi5sc7vetm3aajdt2tppasgg5oquvfjs6lxsfp4ljhj6pq"

    func testCreateGoldHex() {
        let gold = "a2617601626f70a166637265617465a2646e616d656b416c7068612047726f75706867726f75705f69646b67726f75705f616c706861"
        XCTAssertEqual(hex(GroupOpRequest.encode(.create(groupID: "group_alpha", name: "Alpha Group"))), gold)
    }

    func testGrantClawGoldHex() {
        let gold = "a2617601626f70a16a6772616e745f636c6177a267636c61775f69646a636c61775f616c7068616867726f75705f69646b67726f75705f616c706861"
        XCTAssertEqual(hex(GroupOpRequest.encode(.grantClaw(groupID: "group_alpha", clawID: "claw_alpha"))), gold)
    }

    func testAddMemberGoldHex() {
        let gold = "a2617601626f70a16a6164645f6d656d626572a3656c6162656c6b70686f6e655f616c7068616867726f75705f69646b67726f75705f616c706861696d656d6265725f69647836675f6c65717a6d6f6869357363377665746d3361616a64743274707061736767356f717576666a73366c78736670346c6a686a367071"
        XCTAssertEqual(hex(GroupOpRequest.encode(.addMember(groupID: "group_alpha", memberID: memberID, label: "phone_alpha"))), gold)
    }

    func testEnrollMemberDeviceGoldHex() {
        let binding = MemberDeviceBinding(
            kind: "claw-share/member-device/v1",
            memberID: memberID,
            memberPub: bytes("0257e977f6db7e33c3fe7acf2842ed987009caf56d458682fca447b7d3d762ab34"),
            devicePub: bytes("0351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d"),
            participantNpub: "82f283e20094eb4da5922cfba6c0284b790525f4d4ddb2d17fd98f1bd0956c02",
            issuedAt: 1_800_000_000,
            memberSignature: Data(repeating: 0xAB, count: 64)
        )
        let gold = "a2617601626f70a174656e726f6c6c5f6d656d6265725f646576696365a16762696e64696e67a8617601646b696e64781b636c61772d73686172652f6d656d6265722d6465766963652f7631696973737565645f61741a6b49d200696d656d6265725f69647836675f6c65717a6d6f6869357363377665746d3361616a64743274707061736767356f717576666a73366c78736670346c6a686a3670716a6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d6a6d656d6265725f70756258210257e977f6db7e33c3fe7acf2842ed987009caf56d458682fca447b7d3d762ab34706d656d6265725f7369676e61747572655840abababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababab707061727469636970616e745f6e707562784038326632383365323030393465623464613539323263666261366330323834623739303532356634643464646232643137666439386631626430393536633032"
        XCTAssertEqual(hex(GroupOpRequest.encode(.enrollMemberDevice(binding: binding))), gold)
    }

    /// READ-wire seal (3-way): @vivian's `GroupsListResponse` gold hex (`3ccfd4f`)
    /// — the byte-exact `GET /groups` body — decoded by `OwnerGroupsDecoder` into
    /// the snapshot the SHARED APPS screen renders.
    func testGroupsListResponseGoldHex() throws {
        let gold = "a36176016667726f75707381a4646e616d656b416c7068612047726f7570676d656d6265727381a3656c6162656c6d416c69636527732070686f6e65696d656d6265725f69646e675f6d656d6265725f616c7068616c6465766963655f636f756e74016867726f75705f69646b67726f75705f616c7068616d6772616e7465645f636c617773816a636c61775f616c7068616f7075626c69736865645f636c61777380"
        let snapshot = try OwnerGroupsDecoder.decode(bytes(gold))
        XCTAssertEqual(snapshot.groups.count, 1)
        let group = snapshot.groups[0]
        XCTAssertEqual(group.name, "Alpha Group")
        XCTAssertEqual(group.groupID, "group_alpha")
        XCTAssertEqual(group.grantedClaws, ["claw_alpha"])
        XCTAssertEqual(group.members,
                       [OwnerGroupMember(memberID: "g_member_alpha", label: "Alice's phone", deviceCount: 1)])
        XCTAssertTrue(snapshot.publishedClaws.isEmpty)
    }
}
