import Foundation

/// Client for `POST /bootstrap/initialize`.
///
/// Mints house identity (name + P-256 keypair in engine's Secure Enclave/keyring).
/// No auth required — at this point no identity exists yet.
/// `claimToken` proves the pending invitation. After an uncertain response,
/// refresh bootstrap status before deciding whether another initialize is needed.
public struct BootstrapInitializeClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/initialize"

    private static let requiredKeys: Set<String> = ["v", "hh_id", "hh_pub", "pair_qr_uri"]
    private static let knownKeys: Set<String> = requiredKeys.union(["name", "created_at"])

    private let baseURL: URL
    private let perform: TransportPerform

    /// Shared URLSession with a 30s request timeout (vs URLSession.shared's 60s default).
    /// A timeout has an uncertain outcome: the caller must refresh status to
    /// distinguish a completed initialization from a request that never arrived.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await BootstrapInitializeClient.defaultSession.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.perform = transport
    }

    /// Calls `POST /bootstrap/initialize` with the given house name.
    /// - Parameters:
    ///   - name: House name (1–32 UTF-8 chars; no `/`, `:`, `\`, `\0`). Validated server-side.
    ///   - claimToken: Optional 32-byte token from a SetupInvitation (case B). Pass `nil` for case A.
    public func initialize(name: String, claimToken: SetupInvitationToken?) async throws -> BootstrapInitializeResponse {
        // Pre-flight handshake: refuse engines older than
        // `EngineCompat.minSupportedEngineVersion` with a clear message
        // before the main POST. See `docs/engine-protocol-version.md`.
        try await EngineCompat.assertCompatible(
            via: BootstrapStatusClient(baseURL: baseURL, transport: perform)
        )

        let body = Self.encodeRequest(name: name, claimToken: claimToken)
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let data = try await BootstrapWire.send(
            method: "POST", url: url, body: body, authorization: nil, failureStage: .initialize, perform: perform
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
