import Foundation

/// The live `OwnerGroupsReading` — `GET /api/v1/claw-share/groups` (owner-PoP
/// `Operation::HouseholdInvite`, canonical CBOR), decoded into `OwnerGroupsSnapshot`
/// via `OwnerGroupsDecoder`. Drops into the `OwnerGroupsReading` seam in place of
/// `StubOwnerGroupsReader` with no view change. Returns the live ACTIVE roster
/// only (removed/revoked omitted; `device_count` = active enrolled devices).
public struct GETOwnerGroupsReader: OwnerGroupsReading {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/claw-share/groups"

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

    public func fetchOwnerGroups() async throws -> OwnerGroupsSnapshot {
        let (url, pathAndQuery) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        // Owner PoP over the GET (empty body). PoP signer errors propagate verbatim.
        let authorization = try popSigner
            .authorization(method: "GET", pathAndQuery: pathAndQuery, body: Data())
            .authorizationHeader
        let data = try await BootstrapWire.send(
            method: "GET", url: url, body: nil, authorization: authorization, perform: perform
        )
        return try OwnerGroupsDecoder.decode(data)
    }
}
