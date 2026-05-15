import Foundation

/// Client for `POST /bootstrap/teardown`.
///
/// Wipes house state and returns engine to `uninitialized`. The `confirm` field
/// guards against accidental teardowns. Auth is required when state ∈
/// `{named_awaiting_pair, ready, recovering}`; omit (pass `nil`) when
/// state ∈ `{uninitialized, ready_for_naming}` (no key exists yet).
public struct BootstrapTeardownClient: Sendable {
    public typealias AuthorizationProvider = @Sendable (_ method: String, _ pathAndQuery: String, _ body: Data) throws -> String
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/teardown"
    static let confirmConstant = "WIPE_HOUSE"

    private let baseURL: URL
    private let authorizationProvider: AuthorizationProvider?
    private let perform: TransportPerform

    /// Unauthenticated init — use when engine state is `uninitialized` or `ready_for_naming`.
    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.authorizationProvider = nil
        self.perform = transport
    }

    /// Authenticated init — use when a household key exists (state ≥ `named_awaiting_pair`).
    public init(
        baseURL: URL,
        authorizationProvider: @escaping AuthorizationProvider,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.authorizationProvider = authorizationProvider
        self.perform = transport
    }

    /// Authenticated init from a `HouseholdPoPSigner`.
    public init(
        baseURL: URL,
        popSigner: HouseholdPoPSigner,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.authorizationProvider = { method, pathAndQuery, body in
            try popSigner.authorization(method: method, pathAndQuery: pathAndQuery, body: body).authorizationHeader
        }
        self.perform = transport
    }

    /// Issues teardown.
    /// - Parameter wipeKeychain: If `true`, the household private key is removed from SE/keyring.
    public func teardown(wipeKeychain: Bool = true) async throws {
        let body = Self.encodeRequest(wipeKeychain: wipeKeychain)
        let (url, pathAndQuery) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)

        var authorization: String?
        if let provider = authorizationProvider {
            do {
                authorization = try provider("POST", pathAndQuery, body)
            } catch let error as BootstrapError {
                throw error
            } catch {
                throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
            }
        }

        let data = try await BootstrapWire.send(
            method: "POST", url: url, body: body, authorization: authorization, perform: perform
        )
        try Self.decodeAck(data)
    }

    // MARK: - Encode

    static func encodeRequest(wipeKeychain: Bool) -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "confirm": .text(confirmConstant),
            "wipe_keychain": .bool(wipeKeychain),
        ]))
    }

    // MARK: - Decode

    private static func decodeAck(_ data: Data) throws {
        guard case .map(let map) = try BootstrapWire.decodeCanonical(data) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        do {
            try HouseholdCBORMapKeys.requireRequired(map, keys: ["v"])
            try HouseholdCBORMapKeys.requireKnown(map, keys: ["v"])
        } catch {
            throw BootstrapError.protocolViolation(detail: .missingRequiredField)
        }
        guard case .unsigned(1) = map["v"] else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }
}
