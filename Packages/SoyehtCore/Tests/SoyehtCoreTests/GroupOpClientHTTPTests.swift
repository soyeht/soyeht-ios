import XCTest
@testable import SoyehtCore

/// Slice 2: the `GroupOpClient` HTTP layer over `POST /api/v1/claw-share/group-op`
/// (owner PoP + canonical-CBOR body, `204 NO_CONTENT` success). Exercised with an
/// injected transport + a mock owner identity — no live engine.
final class GroupOpClientHTTPTests: XCTestCase {
    private struct MockOwnerIdentity: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(repeating: 0x11, count: 64) }
    }

    /// Thread-safe capture box so the `@Sendable` transport can record the
    /// outbound request for assertions.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ r: URLRequest) { lock.lock(); stored = r; lock.unlock() }
    }

    private func makeClient(
        status: Int,
        responseBody: Data = Data(),
        box: RequestBox? = nil
    ) -> GroupOpClient {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwnerIdentity(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return GroupOpClient(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in
                box?.set(req)
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]
                )!
                return (responseBody, resp)
            }
        )
    }

    func testApplySucceedsOn204AndBuildsRequest() async throws {
        let box = RequestBox()
        let client = makeClient(status: 204, box: box)
        let op: GroupOp = .create(groupID: "g_alpha", name: "Family")

        try await client.apply(op)  // throws on failure; 204 ⇒ success

        let req = box.request
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.path, "/api/v1/claw-share/group-op")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/cbor")
        XCTAssertEqual(req?.httpBody, GroupOpRequest.encode(op))
        let auth = req?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth?.hasPrefix("Soyeht-PoP v1:p_owner:"), true)
    }

    func testApplySucceedsOnAny2xx() async throws {
        let client = makeClient(status: 200)
        try await client.apply(.grantClaw(groupID: "g_alpha", clawID: "claw_x"))
    }

    func testApplyThrowsOnUnauthorized() async {
        let client = makeClient(status: 401)
        do {
            try await client.apply(.grantClaw(groupID: "g_alpha", clawID: "claw_x"))
            XCTFail("expected a throw on 401")
        } catch {
            // any BootstrapError ⇒ the non-2xx path fired
        }
    }

    func testApplyThrowsOnBadRequest() async {
        let client = makeClient(status: 400)
        do {
            try await client.apply(.enrollMemberDevice(binding: MemberDeviceBinding(
                kind: "member-device-binding",
                memberId: "g_dani",
                memberPublicKey: Data(repeating: 0x02, count: 33),
                devicePublicKey: Data(repeating: 0x03, count: 33),
                participantNpub: "",
                issuedAt: 1_800_000_000,
                memberSignature: Data(repeating: 0x44, count: 64)
            )))
            XCTFail("expected a throw on 400")
        } catch {
            // member_binding_invalid etc. ⇒ thrown
        }
    }

    /// The signed PoP context binds the exact body bytes, so two identical ops
    /// produce identical request bodies (the engine re-hashes the body).
    func testRequestBodyMatchesEncoder() async throws {
        let box = RequestBox()
        let client = makeClient(status: 204, box: box)
        try await client.apply(.publishClaw(clawID: "claw_x"))
        XCTAssertEqual(box.request?.httpBody, GroupOpRequest.encode(.publishClaw(clawID: "claw_x")))
    }
}
