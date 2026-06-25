import XCTest
@testable import SoyehtCore

/// The live `OwnerGroupsReading` adapter: `GET /api/v1/claw-share/groups`
/// (owner-PoP) → `OwnerGroupsDecoder` → `OwnerGroupsSnapshot`. Exercised with an
/// injected transport + mock owner identity — no live engine.
final class GETOwnerGroupsReaderTests: XCTestCase {
    private struct MockOwner: OwnerIdentitySigning {
        var personId = "p_owner"
        var publicKey = Data(repeating: 0x02, count: 33)
        var keyReference = "mock-owner-key"
        func sign(_ payload: Data) throws -> Data { Data(repeating: 0x11, count: 64) }
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ r: URLRequest) { lock.lock(); stored = r; lock.unlock() }
    }

    private func sampleBody() -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "groups": .array([
                .map([
                    "group_id": .text("g_family"),
                    "name": .text("Family"),
                    "members": .array([
                        .map([
                            "member_id": .text("g_dani"),
                            "label": .text("Dani"),
                            "device_count": .unsigned(1),
                        ]),
                    ]),
                    "granted_claws": .array([.text("claw_x")]),
                ]),
            ]),
            "published_claws": .array([.text("claw_pub")]),
        ]))
    }

    private func makeReader(status: Int, body: Data, box: RequestBox? = nil) -> GETOwnerGroupsReader {
        let signer = HouseholdPoPSigner(
            ownerIdentity: MockOwner(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return GETOwnerGroupsReader(
            baseURL: URL(string: "https://engine.example")!,
            popSigner: signer,
            transport: { req in
                box?.set(req)
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/cbor"]
                )!
                return (body, resp)
            }
        )
    }

    func testFetchDecodesSnapshotAndBuildsOwnerPoPGet() async throws {
        let box = RequestBox()
        let reader = makeReader(status: 200, body: sampleBody(), box: box)
        let snap = try await reader.fetchOwnerGroups()

        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.groups.first?.name, "Family")
        XCTAssertEqual(snap.groups.first?.members.first,
                       OwnerGroupMember(memberID: "g_dani", label: "Dani", deviceCount: 1))
        XCTAssertEqual(snap.groups.first?.grantedClaws, ["claw_x"])
        XCTAssertEqual(snap.publishedClaws, ["claw_pub"])

        XCTAssertEqual(box.request?.httpMethod, "GET")
        XCTAssertEqual(box.request?.url?.path, "/api/v1/claw-share/groups")
        XCTAssertEqual(box.request?.value(forHTTPHeaderField: "Authorization")?
            .hasPrefix("Soyeht-PoP v1:p_owner:"), true)
    }

    func testFetchThrowsOnUnauthorized() async {
        let reader = makeReader(status: 401, body: Data())
        do {
            _ = try await reader.fetchOwnerGroups()
            XCTFail("expected a throw on 401")
        } catch {
            // BootstrapError from the non-2xx path
        }
    }
}
