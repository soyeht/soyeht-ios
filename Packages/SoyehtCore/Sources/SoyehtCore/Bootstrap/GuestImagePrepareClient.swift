import Foundation

/// Request body for `POST /api/v1/household/guest-image/prepare`.
public struct GuestImagePrepareBody: Encodable, Sendable {
    public let force: Bool
    public init(force: Bool) { self.force = force }
}

/// Wire response from `POST /api/v1/household/guest-image/prepare` (its shape
/// mirrors the guest-image fields on `GET /bootstrap/status`). Shared so iOS and
/// macOS decode the same shape; each surface maps it onto its own gate type.
/// Decoded via the API client's `.convertFromSnakeCase` strategy.
public struct GuestImagePrepareResponse: Decodable, Equatable, Sendable {
    public let v: Int
    public let status: String
    public let guestImagePhase: String?
    public let guestImageStatus: String?
    public let guestImageError: String?
    /// Machine-readable failure reason (theyos PR #89). Fail-soft: unknown/future
    /// codes decode to `.unknown`; absent on older engines.
    public let guestImageFailureCode: GuestImageFailureCode?

    public init(
        v: Int,
        status: String,
        guestImagePhase: String?,
        guestImageStatus: String?,
        guestImageError: String?,
        guestImageFailureCode: GuestImageFailureCode?
    ) {
        self.v = v
        self.status = status
        self.guestImagePhase = guestImagePhase
        self.guestImageStatus = guestImageStatus
        self.guestImageError = guestImageError
        self.guestImageFailureCode = guestImageFailureCode
    }
}

/// Shared thin client that TRIGGERS guest-image preparation on a Mac engine — a
/// single idempotent `POST /api/v1/household/guest-image/prepare` (owner-PoP
/// gated by `claws.create`). The caller refreshes `/bootstrap/status` afterward
/// to reflect the authoritative state. iOS wraps this with its own gate mapping;
/// macOS calls it from the Claw Store readiness model.
@MainActor
public final class GuestImagePrepareClient {
    public typealias PrepareRequest = (URL, Bool) async throws -> GuestImagePrepareResponse

    public static let shared = GuestImagePrepareClient()

    private let prepareRequest: PrepareRequest

    public init(
        apiClient: SoyehtAPIClient = .shared,
        prepareRequest: PrepareRequest? = nil
    ) {
        if let prepareRequest {
            self.prepareRequest = prepareRequest
            return
        }
        self.prepareRequest = { endpoint, force in
            let body: Data?
            var headers = ["Accept": "application/json"]
            if force {
                body = try apiClient.encoder.encode(GuestImagePrepareBody(force: true))
                headers["Content-Type"] = "application/json"
            } else {
                body = nil
            }
            let (data, _) = try await apiClient.householdRequest(
                endpoint: endpoint,
                path: "/api/v1/household/guest-image/prepare",
                method: "POST",
                body: body,
                requiredOperation: "claws.create",
                additionalHeaders: headers
            )
            return try apiClient.decoder.decode(GuestImagePrepareResponse.self, from: data)
        }
    }

    public func prepare(endpoint: URL, force: Bool = false) async throws -> GuestImagePrepareResponse {
        try await prepareRequest(endpoint, force)
    }
}
