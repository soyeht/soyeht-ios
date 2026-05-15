import Foundation

/// Client for `POST /bootstrap/initialize`.
///
/// Mints house identity (name + P-256 keypair in engine's Secure Enclave/keyring).
/// No auth required — at this point no identity exists yet.
/// Idempotent via `claimToken` (case B): same token → same `hh_pub` on retry.
public struct BootstrapInitializeClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/initialize"

    private static let requiredKeys: Set<String> = ["v", "hh_id", "hh_pub", "pair_qr_uri"]
    private static let knownKeys: Set<String> = requiredKeys.union(["name", "created_at"])

    private let baseURL: URL
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.perform = transport
    }

    /// Calls `POST /bootstrap/initialize` with the given house name.
    /// - Parameters:
    ///   - name: House name (1–32 UTF-8 chars; no `/`, `:`, `\`, `\0`). Validated server-side.
    ///   - claimToken: Optional 32-byte token from a SetupInvitation (case B). Pass `nil` for case A.
    public func initialize(name: String, claimToken: SetupInvitationToken?) async throws -> BootstrapInitializeResponse {
        let body = Self.encodeRequest(name: name, claimToken: claimToken)
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let data = try await BootstrapWire.send(
            method: "POST", url: url, body: body, authorization: nil, perform: perform
        )
        return try Self.decode(data)
    }

    // MARK: - Encode

    static func encodeRequest(name: String, claimToken: SetupInvitationToken?) -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "name": .text(name),
        ]
        if let token = claimToken {
            map["claim_token"] = .bytes(token.bytes)
        } else {
            map["claim_token"] = .null
        }
        return HouseholdCBOR.encode(.map(map))
    }

    // MARK: - Decode

    private static func decode(_ data: Data) throws -> BootstrapInitializeResponse {
        guard case .map(let map) = try BootstrapWire.decodeCanonical(data) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        do {
            try HouseholdCBORMapKeys.requireRequired(map, keys: requiredKeys)
            try HouseholdCBORMapKeys.requireKnown(map, keys: knownKeys)
        } catch {
            throw BootstrapError.protocolViolation(detail: .missingRequiredField)
        }
        guard case .unsigned(1) = map["v"],
              case .text(let hhId) = map["hh_id"],
              case .bytes(let hhPub) = map["hh_pub"],
              case .text(let pairQrUri) = map["pair_qr_uri"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard hhPub.count == 33 else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return BootstrapInitializeResponse(version: 1, hhId: hhId, hhPub: hhPub, pairQrUri: pairQrUri)
    }
}
