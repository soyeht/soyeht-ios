import Foundation

/// Client for `POST /bootstrap/claim-setup-invitation`.
///
/// Mac calls this on its OWN engine immediately after AirDrop-install + discovery
/// of the iPhone's `_soyeht-setup._tcp.` Bonjour service. The engine stores the
/// token so the subsequent `POST /bootstrap/initialize` skips house-naming on Mac
/// and uses the iPhone-provided `owner_display_name` instead.
///
/// Auth: none. Engine must be `uninitialized` or `ready_for_naming`.
public struct SetupInvitationClaimClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/claim-setup-invitation"

    private static let requiredKeys: Set<String> = ["v", "accepted_at"]
    private static let knownKeys: Set<String> = requiredKeys

    private let baseURL: URL
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.perform = transport
    }

    /// Claims the setup invitation token.
    /// - Parameters:
    ///   - token: 32-byte token from the Bonjour TXT record.
    ///   - ownerDisplayName: Name hint from the TXT record; forwarded to engine as initialization hint.
    ///   - iphoneApnsToken: APNs device token from the iPhone; engine uses it to push "casa nasceu".
    /// - Returns: Unix timestamp of acceptance from the engine.
    @discardableResult
    public func claim(
        token: SetupInvitationToken,
        ownerDisplayName: String?,
        iphoneApnsToken: Data?
    ) async throws -> UInt64 {
        let body = Self.encodeRequest(
            token: token,
            ownerDisplayName: ownerDisplayName,
            iphoneApnsToken: iphoneApnsToken
        )
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let data = try await BootstrapWire.send(
            method: "POST", url: url, body: body, authorization: nil, perform: perform
        )
        return try Self.decode(data)
    }

    // MARK: - Encode

    static func encodeRequest(
        token: SetupInvitationToken,
        ownerDisplayName: String?,
        iphoneApnsToken: Data?
    ) -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "token": .bytes(token.bytes),
        ]
        map["owner_display_name"] = ownerDisplayName.map { .text($0) } ?? .null
        map["iphone_apns_token"] = iphoneApnsToken.map { .bytes($0) } ?? .null
        return HouseholdCBOR.encode(.map(map))
    }

    // MARK: - Decode

    private static func decode(_ data: Data) throws -> UInt64 {
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
              case .unsigned(let acceptedAt) = map["accepted_at"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return acceptedAt
    }
}
