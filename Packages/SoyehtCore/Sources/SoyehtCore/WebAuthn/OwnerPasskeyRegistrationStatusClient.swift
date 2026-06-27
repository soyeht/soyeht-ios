import Foundation

// MARK: - Status DTOs

/// The owner passkey first-enrollment status request body: canonical CBOR `{ v: 1 }`.
public struct OwnerPasskeyRegistrationStatusRequest: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1

    public let version: UInt8

    public init(version: UInt8 = Self.currentVersion) {
        self.version = version
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(.map([
            "v": .unsigned(UInt64(version)),
        ]))
    }
}

/// Minimal status response for first-enrollment E1 recovery.
///
/// The server exposes only whether owner passkey enrollment has ever committed.
/// It deliberately does not expose recovery state, anchor state, credential ids,
/// counts, or failure reasons. Callers must branch only on successful responses;
/// a thrown error, including the opaque `401`, remains a generic failure.
public struct OwnerPasskeyRegistrationStatusResponse: Equatable, Sendable {
    public let version: UInt8
    public let enrolled: Bool

    public init(version: UInt8, enrolled: Bool) {
        self.version = version
        self.enrolled = enrolled
    }

    public init(cbor: HouseholdCBORValue) throws {
        let map = try cbor.cborMap("statusResponse")
        version = try cborUInt8(cborRequire(map, "v", "statusResponse"), "statusResponse.v")
        enrolled = try cborRequire(map, "enrolled", "statusResponse").cborBool("statusResponse.enrolled")
    }
}

// MARK: - Client

/// Headless HTTP client for owner passkey first-enrollment status.
///
/// This endpoint is an E1 UX aid after an opaque start/finish failure. It is
/// authenticated with owner PoP and returns only `{ v, enrolled }` on success.
/// Any reject flows through ``BootstrapWire`` as a generic `BootstrapError`;
/// the client must not infer recovery, anchor, or retry reasons from errors.
public struct OwnerPasskeyRegistrationStatusClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/household/owner-webauthn/registration/status"

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

    /// Reads first-enrollment status. Successful responses are the only values
    /// callers may branch on: `enrolled == true` means a passkey enrollment
    /// already committed; `false` means genuinely never enrolled. Errors remain
    /// opaque and must not drive blind re-enrollment.
    public func fetch() async throws -> OwnerPasskeyRegistrationStatusResponse {
        let body = OwnerPasskeyRegistrationStatusRequest().canonicalBytes()
        let data = try await post(path: Self.path, body: body)
        return try OwnerPasskeyRegistrationStatusResponse(cbor: BootstrapWire.decodeCanonical(data))
    }

    private func post(path: String, body: Data) async throws -> Data {
        let (url, pathAndQuery) = BootstrapWire.endpointURL(baseURL: baseURL, path: path)
        let authorization = try popSigner
            .authorization(method: "POST", pathAndQuery: pathAndQuery, body: body)
            .authorizationHeader
        return try await BootstrapWire.send(
            method: "POST",
            url: url,
            body: body,
            authorization: authorization,
            perform: perform
        )
    }
}

// MARK: - CBOR helpers

private extension HouseholdCBORValue {
    func cborMap(_ context: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = self else {
            throw OwnerWebauthnRegistrationDTOError.malformedCBOR("\(context): expected map")
        }
        return map
    }

    func cborUnsigned(_ context: String) throws -> UInt64 {
        guard case .unsigned(let value) = self else {
            throw OwnerWebauthnRegistrationDTOError.malformedCBOR("\(context): expected unsigned integer")
        }
        return value
    }

    func cborBool(_ context: String) throws -> Bool {
        guard case .bool(let value) = self else {
            throw OwnerWebauthnRegistrationDTOError.malformedCBOR("\(context): expected bool")
        }
        return value
    }
}

private func cborRequire(
    _ map: [String: HouseholdCBORValue],
    _ key: String,
    _ context: String
) throws -> HouseholdCBORValue {
    guard let value = map[key] else {
        throw OwnerWebauthnRegistrationDTOError.malformedCBOR("\(context): missing key '\(key)'")
    }
    return value
}

private func cborUInt8(_ value: HouseholdCBORValue, _ context: String) throws -> UInt8 {
    let raw = try value.cborUnsigned(context)
    guard let narrowed = UInt8(exactly: raw) else {
        throw OwnerWebauthnRegistrationDTOError.malformedCBOR("\(context): \(raw) out of UInt8 range")
    }
    return narrowed
}
