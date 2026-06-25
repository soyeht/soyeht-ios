import XCTest
@testable import SoyehtCore

/// Slice 1 of the owner UX over `POST /api/v1/claw-share/group-op`: the typed
/// canonical-CBOR encoder for `GroupOpRequest { v: 1, op }`, mirroring the Rust
/// `handlers_claw_share.rs` GroupOp (externally-tagged, snake_case).
///
/// These prove the encoder is well-formed canonical CBOR with the exact
/// externally-tagged shape + snake_case field names. The cross-language
/// byte-parity fixture (Rust-generated gold hex, same recipe as the relay-offer
/// lockstep) is pinned in `testMatchesRustCanonicalGoldHex` once it lands.
final class GroupOpClientTests: XCTestCase {
    private enum ShapeError: Error { case notMap, noOp, notSingleTag, fieldsNotMap }

    /// Encode → decode → return (v, the single variant tag, its field map).
    private func roundTrip(_ op: GroupOp) throws -> (v: HouseholdCBORValue?, tag: String, fields: [String: HouseholdCBORValue]) {
        let data = GroupOpRequest.encode(op)
        guard case let .map(top) = try HouseholdCBOR.decode(data) else { throw ShapeError.notMap }
        guard case let .map(opMap)? = top["op"] else { throw ShapeError.noOp }
        guard opMap.count == 1, let (tag, value) = opMap.first else { throw ShapeError.notSingleTag }
        guard case let .map(fields) = value else { throw ShapeError.fieldsNotMap }
        return (top["v"], tag, fields)
    }

    func testCreate() throws {
        let r = try roundTrip(.create(groupID: "g_alpha", name: "Family"))
        XCTAssertEqual(r.v, .unsigned(1))
        XCTAssertEqual(r.tag, "create")
        XCTAssertEqual(r.fields, ["group_id": .text("g_alpha"), "name": .text("Family")])
    }

    func testRename() throws {
        let r = try roundTrip(.rename(groupID: "g_alpha", name: "Inner circle"))
        XCTAssertEqual(r.tag, "rename")
        XCTAssertEqual(r.fields, ["group_id": .text("g_alpha"), "name": .text("Inner circle")])
    }

    func testAddMember() throws {
        let r = try roundTrip(.addMember(groupID: "g_alpha", memberID: "g_dani", label: "Dani"))
        XCTAssertEqual(r.tag, "add_member")
        XCTAssertEqual(r.fields, [
            "group_id": .text("g_alpha"),
            "member_id": .text("g_dani"),
            "label": .text("Dani"),
        ])
    }

    func testRemoveMember() throws {
        let r = try roundTrip(.removeMember(groupID: "g_alpha", memberID: "g_dani"))
        XCTAssertEqual(r.tag, "remove_member")
        XCTAssertEqual(r.fields, ["group_id": .text("g_alpha"), "member_id": .text("g_dani")])
    }

    func testGrantClaw() throws {
        let r = try roundTrip(.grantClaw(groupID: "g_alpha", clawID: "claw_x"))
        XCTAssertEqual(r.tag, "grant_claw")
        XCTAssertEqual(r.fields, ["group_id": .text("g_alpha"), "claw_id": .text("claw_x")])
    }

    func testRevokeClaw() throws {
        let r = try roundTrip(.revokeClaw(groupID: "g_alpha", clawID: "claw_x"))
        XCTAssertEqual(r.tag, "revoke_claw")
        XCTAssertEqual(r.fields, ["group_id": .text("g_alpha"), "claw_id": .text("claw_x")])
    }

    func testEnrollMemberDevice() throws {
        let binding = MemberDeviceBinding(
            kind: "member-device-binding",
            memberId: "g_dani",
            memberPublicKey: Data(repeating: 0x02, count: 33),
            devicePublicKey: Data(repeating: 0x03, count: 33),
            participantNpub: "npub1danimesh",
            issuedAt: 1_800_000_000,
            memberSignature: Data(repeating: 0x44, count: 64)
        )
        let r = try roundTrip(.enrollMemberDevice(binding: binding))
        XCTAssertEqual(r.tag, "enroll_member_device")
        guard case let .map(b)? = r.fields["binding"] else { return XCTFail("binding not a map") }
        XCTAssertEqual(b["v"], .unsigned(1))
        XCTAssertEqual(b["kind"], .text("member-device-binding"))
        XCTAssertEqual(b["member_id"], .text("g_dani"))
        XCTAssertEqual(b["member_pub"], .bytes(Data(repeating: 0x02, count: 33)))
        XCTAssertEqual(b["device_pub"], .bytes(Data(repeating: 0x03, count: 33)))
        XCTAssertEqual(b["participant_npub"], .text("npub1danimesh"))
        XCTAssertEqual(b["issued_at"], .unsigned(1_800_000_000))
        XCTAssertEqual(b["member_signature"], .bytes(Data(repeating: 0x44, count: 64)))
    }

    func testRetireMemberDevice() throws {
        let r = try roundTrip(.retireMemberDevice(memberID: "g_dani", devicePub: Data(repeating: 0x03, count: 33)))
        XCTAssertEqual(r.tag, "retire_member_device")
        XCTAssertEqual(r.fields, [
            "member_id": .text("g_dani"),
            "device_pub": .bytes(Data(repeating: 0x03, count: 33)),
        ])
    }

    func testPublishAndUnpublish() throws {
        let p = try roundTrip(.publishClaw(clawID: "claw_x"))
        XCTAssertEqual(p.tag, "publish_claw")
        XCTAssertEqual(p.fields, ["claw_id": .text("claw_x")])
        let u = try roundTrip(.unpublishClaw(clawID: "claw_x"))
        XCTAssertEqual(u.tag, "unpublish_claw")
        XCTAssertEqual(u.fields, ["claw_id": .text("claw_x")])
    }

    /// Canonical encoding is deterministic — identical input ⇒ identical bytes.
    func testEncodingIsDeterministic() {
        let a = GroupOpRequest.encode(.grantClaw(groupID: "g_alpha", clawID: "claw_x"))
        let b = GroupOpRequest.encode(.grantClaw(groupID: "g_alpha", clawID: "claw_x"))
        XCTAssertEqual(a, b)
    }

    /// Envelope: top map is exactly `{ v, op }` and version is 1.
    func testEnvelopeShape() throws {
        let data = GroupOpRequest.encode(.publishClaw(clawID: "claw_x"))
        guard case let .map(top) = try HouseholdCBOR.decode(data) else { return XCTFail("not a map") }
        XCTAssertEqual(Set(top.keys), ["v", "op"])
        XCTAssertEqual(top["v"], .unsigned(1))
    }

    // Cross-language byte-parity — pinned when @vivian's Rust gold hex lands
    // (same recipe as the relay-offer lockstep: additive `#[derive(Serialize)]`
    // on GroupOp/GroupOpRequest + `cbor::to_canonical_vec` → hex). Will assert
    // `GroupOpRequest.encode(...)` byte-matches the Rust canonical encoding.
    //
    // func testMatchesRustCanonicalGoldHex() throws {
    //     let expected = Data(hex: "<vivian gold hex for create{g_alpha,Family}>")
    //     XCTAssertEqual(GroupOpRequest.encode(.create(groupID: "g_alpha", name: "Family")), expected)
    // }
}
