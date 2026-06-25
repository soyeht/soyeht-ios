import Foundation

/// One owner action against the first-class group model, mirroring the Rust
/// `GroupOp` (`server-rs/src/handlers_claw_share.rs`). The owner POSTs
/// `GroupOpRequest { v: 1, op }` (canonical CBOR) to
/// `POST /api/v1/claw-share/group-op` under an owner PoP
/// (`Operation::HouseholdInvite`); the engine appends one signed `MeshEvent`
/// and republishes the affected rosters.
///
/// Wire shape: the op is **externally-tagged** canonical CBOR with snake_case
/// keys — `{ "<variant>": { <fields> } }` — matching serde
/// `#[serde(rename_all = "snake_case")]` on the Rust enum. Byte-parity with the
/// Rust `cbor::from_canonical_slice` decoder is pinned by a cross-language
/// fixture in the tests.
public enum GroupOp: Equatable, Sendable {
    case create(groupID: String, name: String)
    case rename(groupID: String, name: String)
    case addMember(groupID: String, memberID: String, label: String)
    case removeMember(groupID: String, memberID: String)
    case grantClaw(groupID: String, clawID: String)
    case revokeClaw(groupID: String, clawID: String)
    case enrollMemberDevice(binding: MemberDeviceBinding)
    case retireMemberDevice(memberID: String, devicePub: Data)
    case publishClaw(clawID: String)
    case unpublishClaw(clawID: String)

    var cborValue: HouseholdCBORValue {
        switch self {
        case let .create(groupID, name):
            return .map(["create": .map(["group_id": .text(groupID), "name": .text(name)])])
        case let .rename(groupID, name):
            return .map(["rename": .map(["group_id": .text(groupID), "name": .text(name)])])
        case let .addMember(groupID, memberID, label):
            return .map(["add_member": .map([
                "group_id": .text(groupID),
                "member_id": .text(memberID),
                "label": .text(label),
            ])])
        case let .removeMember(groupID, memberID):
            return .map(["remove_member": .map([
                "group_id": .text(groupID),
                "member_id": .text(memberID),
            ])])
        case let .grantClaw(groupID, clawID):
            return .map(["grant_claw": .map(["group_id": .text(groupID), "claw_id": .text(clawID)])])
        case let .revokeClaw(groupID, clawID):
            return .map(["revoke_claw": .map(["group_id": .text(groupID), "claw_id": .text(clawID)])])
        case let .enrollMemberDevice(binding):
            return .map(["enroll_member_device": .map(["binding": binding.cborValue])])
        case let .retireMemberDevice(memberID, devicePub):
            return .map(["retire_member_device": .map([
                "member_id": .text(memberID),
                "device_pub": .bytes(devicePub),
            ])])
        case let .publishClaw(clawID):
            return .map(["publish_claw": .map(["claw_id": .text(clawID)])])
        case let .unpublishClaw(clawID):
            return .map(["unpublish_claw": .map(["claw_id": .text(clawID)])])
        }
    }
}

/// Canonical-CBOR body for `POST /api/v1/claw-share/group-op` — the foundation
/// the owner-UX SwiftUI surface (and any client) encodes before signing the
/// owner PoP. No transport here; this slice is the typed encoder only.
public enum GroupOpRequest {
    public static let version: UInt64 = 1

    /// Canonical CBOR of `{ v: 1, op: <externally-tagged op> }`.
    public static func encode(_ op: GroupOp) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(version),
            "op": op.cborValue,
        ]))
    }
}

/// Client for `POST /api/v1/claw-share/group-op` — the owner applies one
/// `GroupOp` (one signed `MeshEvent` + roster republish) authenticated via
/// Soyeht-PoP v1 (`Operation::HouseholdInvite`). Success is engine
/// `204 NO_CONTENT` (empty body, no Content-Type); non-2xx surfaces as
/// `BootstrapError`. The transport is injectable, so the owner-UX flow is
/// exercisable with no live engine. This replaces curl/friend-cli in the
/// user-facing group-management flow (release gate 5).
public struct GroupOpClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/claw-share/group-op"

    private let baseURL: URL
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        popSigner: HouseholdPoPSigner,
        transport: @escaping TransportPerform = { req in
            try await BootstrapInitializeClient.defaultSession.data(for: req)
        }
    ) {
        self.baseURL = baseURL
        self.popSigner = popSigner
        self.perform = transport
    }

    /// Apply one owner group op. Returns on engine `204 NO_CONTENT`; throws
    /// `BootstrapError` on any non-2xx (e.g. `401` failed owner PoP, `400`
    /// `member_binding_invalid`, `503` `household_unavailable`). PoP signer
    /// errors (`biometryCanceled`, …) propagate verbatim so the UI can show a
    /// "Cancelled" state instead of a generic network error.
    public func apply(_ op: GroupOp) async throws {
        let body = GroupOpRequest.encode(op)
        let (url, pathAndQuery) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let authorization = try popSigner
            .authorization(method: "POST", pathAndQuery: pathAndQuery, body: body)
            .authorizationHeader

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(BootstrapWire.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let response: URLResponse
        let data: Data
        do {
            (data, response) = try await perform(request)
        } catch let error as BootstrapError {
            throw error
        } catch {
            throw BootstrapError.networkDrop
        }

        guard let http = response as? HTTPURLResponse else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard (200..<300).contains(http.statusCode) else {
            // The engine's error_response body is canonical CBOR; decodeError
            // tolerates an empty/opaque body (e.g. a bare 401) and falls back.
            throw BootstrapWire.decodeError(data)
        }
        // 204 NO_CONTENT (or any 2xx): success — one signed MeshEvent appended.
    }
}
