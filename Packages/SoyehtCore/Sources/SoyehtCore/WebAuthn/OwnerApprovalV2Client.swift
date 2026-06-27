import Foundation

// MARK: - approval-v2/start request

/// The `approval-v2/start` request body: canonical CBOR `{ v: 1 }`.
public struct OwnerApprovalV2StartRequest: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public var version: UInt8

    public init(version: UInt8 = OwnerApprovalV2StartRequest.currentVersion) {
        self.version = version
    }

    public func cborValue() -> HouseholdCBORValue {
        .map(["v": .unsigned(UInt64(version))])
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue())
    }
}

// MARK: - Client

/// Headless HTTP client for the owner approval-v2 ceremony.
///
/// `start(cursor:)` POSTs the start request and decodes the
/// ``OwnerApprovalV2StartResponse`` (challenge + bound context + assertion
/// options). `approveV2(cursor:finish:)` encodes the signed
/// ``OwnerApprovalV2Finish`` envelope and POSTs it to the polymorphic
/// `/owner-events/{cursor}/approve` endpoint.
///
/// Both calls are authenticated with a fresh Soyeht-PoP over
/// `method + pathAndQuery + body` (recomputed per request via the stored
/// signer), and go through ``BootstrapWire`` so any reject — including the
/// intentionally opaque `401` — surfaces as a generic `BootstrapError`
/// (`.serverError(code: "unauthenticated", message: nil)`), never a typed reason.
///
/// No UI, no live `PasskeyProvider.authenticate()`, no enforcement flip: this is
/// the transport seam the approval orchestrator will drive later.
public struct OwnerApprovalV2Client: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

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

    static func startPath(cursor: UInt64) -> String {
        "/api/v1/household/owner-events/\(cursor)/approval-v2/start"
    }

    static func approvePath(cursor: UInt64) -> String {
        "/api/v1/household/owner-events/\(cursor)/approve"
    }

    /// Starts an approval-v2 ceremony and returns the server's challenge + the
    /// bound context + the platform-assertion options.
    public func start(cursor: UInt64) async throws -> OwnerApprovalV2StartResponse {
        let body = OwnerApprovalV2StartRequest().canonicalBytes()
        let data = try await post(path: Self.startPath(cursor: cursor), body: body)
        return try OwnerApprovalV2StartResponse(cbor: BootstrapWire.decodeCanonical(data))
    }

    /// Finishes an approval-v2 ceremony by posting the signed envelope. Succeeds
    /// on any `2xx`; any reject throws a generic `BootstrapError` (the opaque
    /// `401` becomes `.serverError(code: "unauthenticated", message: nil)`).
    public func approveV2(cursor: UInt64, finish: OwnerApprovalV2Finish) async throws {
        _ = try await post(path: Self.approvePath(cursor: cursor), body: finish.canonicalBytes())
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
