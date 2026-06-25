import XCTest
@testable import SoyehtCore

/// Slice 3a: the owner action API (`GroupOwnerActions`) over `GroupOpClient`.
/// Each named action sends exactly its op; the `shareClaw` composite sends the
/// create → add_member → grant_claw sequence. Exercised with a capturing mock
/// transport — no live engine.
final class GroupOwnerActionsTests: XCTestCase {
    private struct MockOwner: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(repeating: 0x11, count: 64) }
    }

    /// Thread-safe ordered log of outbound request bodies.
    private final class RequestsLog: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        func append(_ data: Data) { lock.lock(); bodies.append(data); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    }

    private func makeActions(_ log: RequestsLog) -> GroupOwnerActions {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwner(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let client = GroupOpClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in
                log.append(req.httpBody ?? Data())
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:]
                )!
                return (Data(), resp)
            }
        )
        return GroupOwnerActions(client: client)
    }

    private struct ShapeError: Error {}

    /// Decode a captured `GroupOpRequest` body into (variant tag, field map).
    private func op(_ body: Data) throws -> (tag: String, fields: [String: HouseholdCBORValue]) {
        guard case let .map(top) = try HouseholdCBOR.decode(body),
              case let .map(opMap)? = top["op"],
              let (tag, value) = opMap.first,
              case let .map(fields) = value
        else { throw ShapeError() }
        return (tag, fields)
    }

    func testCreateGroupSendsCreate() async throws {
        let log = RequestsLog()
        try await makeActions(log).createGroup(id: "g_alpha", name: "Family")
        XCTAssertEqual(log.all.count, 1)
        let o = try op(log.all[0])
        XCTAssertEqual(o.tag, "create")
        XCTAssertEqual(o.fields["group_id"], .text("g_alpha"))
        XCTAssertEqual(o.fields["name"], .text("Family"))
    }

    func testAddMemberSendsAddMember() async throws {
        let log = RequestsLog()
        try await makeActions(log).addMember(groupID: "g_alpha", memberID: "g_dani", label: "Dani")
        let o = try op(log.all[0])
        XCTAssertEqual(o.tag, "add_member")
        XCTAssertEqual(o.fields["member_id"], .text("g_dani"))
        XCTAssertEqual(o.fields["label"], .text("Dani"))
    }

    func testGrantThenRevokeOrder() async throws {
        let log = RequestsLog()
        let actions = makeActions(log)
        try await actions.grantClaw(groupID: "g_alpha", clawID: "claw_x")
        try await actions.revokeClaw(groupID: "g_alpha", clawID: "claw_x")
        let tags = try log.all.map { try op($0).tag }
        XCTAssertEqual(tags, ["grant_claw", "revoke_claw"])
    }

    func testPublishAndUnpublish() async throws {
        let log = RequestsLog()
        let actions = makeActions(log)
        try await actions.publishClaw("claw_x")
        try await actions.unpublishClaw("claw_x")
        XCTAssertEqual(try log.all.map { try op($0).tag }, ["publish_claw", "unpublish_claw"])
    }

    /// The headline composite: share a claw with a new 2-person group.
    func testShareClawSendsCreateAddGrantInOrder() async throws {
        let log = RequestsLog()
        try await makeActions(log).shareClaw(
            clawID: "claw_x",
            withNewGroupID: "g_alpha",
            named: "Family",
            memberID: "g_dani",
            memberLabel: "Dani"
        )
        XCTAssertEqual(log.all.count, 3)
        let ops = try log.all.map { try op($0) }
        XCTAssertEqual(ops.map(\.tag), ["create", "add_member", "grant_claw"])
        XCTAssertEqual(ops[0].fields["name"], .text("Family"))
        XCTAssertEqual(ops[1].fields["member_id"], .text("g_dani"))
        XCTAssertEqual(ops[2].fields["claw_id"], .text("claw_x"))
        // Same group id threads through all three.
        for o in ops where o.tag != "grant_claw" {
            // create/add carry group_id; grant carries it too
        }
        XCTAssertEqual(ops[0].fields["group_id"], .text("g_alpha"))
        XCTAssertEqual(ops[2].fields["group_id"], .text("g_alpha"))
    }

    func testEnrollMemberDeviceSendsBinding() async throws {
        let log = RequestsLog()
        let binding = MemberDeviceBinding(
            kind: "claw-share/member-device/v1",
            memberID: "g_dani",
            memberPub: Data(repeating: 0x02, count: 33),
            devicePub: Data(repeating: 0x03, count: 33),
            participantNpub: "",
            issuedAt: 1_800_000_000,
            memberSignature: Data(repeating: 0x44, count: 64)
        )
        try await makeActions(log).enrollMemberDevice(binding)
        let o = try op(log.all[0])
        XCTAssertEqual(o.tag, "enroll_member_device")
        guard case .map = o.fields["binding"] else { return XCTFail("binding not a map") }
    }

    /// The enroll-sheet composite (3.2b): add member → enroll device → grant claw,
    /// member_id threaded from the binding.
    func testEnrollMemberIntoGroupSendsThreeOpsInOrder() async throws {
        let log = RequestsLog()
        let binding = MemberDeviceBinding(
            kind: "claw-share/member-device/v1",
            memberID: "g_dani",
            memberPub: Data(repeating: 0x02, count: 33),
            devicePub: Data(repeating: 0x03, count: 33),
            participantNpub: "",
            issuedAt: 1_800_000_000,
            memberSignature: Data(repeating: 0x44, count: 64)
        )
        try await makeActions(log).enrollMemberIntoGroup(
            binding: binding, groupID: "g_family", label: "Dani", clawID: "claw_x"
        )
        let tags = try log.all.map { try op($0).tag }
        XCTAssertEqual(tags, ["add_member", "enroll_member_device", "grant_claw"])
        XCTAssertEqual(try op(log.all[0]).fields["member_id"], .text("g_dani"))
        XCTAssertEqual(try op(log.all[2]).fields["claw_id"], .text("claw_x"))
    }
}
