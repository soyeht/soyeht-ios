#if canImport(AuthenticationServices)
import Foundation

/// Headless coordinator for owner passkey **first enrollment** (SPM logic; no UI,
/// no app-target).
///
/// Drives: `client.start()` → platform passkey **registration** ceremony (create)
/// → `client.finish(...)` with the resulting attestation. The enrollment VM/screen
/// calls `enroll()` from a dedicated setup step (with a first-class "set up later"
/// skip that simply doesn't call this).
///
/// Fail-closed: any error propagates unchanged and aborts before the next step —
/// a `start` reject never reaches the ceremony, and a cancelled/failed
/// registration never reaches `finish`. Server rejects surface as the generic
/// `BootstrapError` (no reason inference, no branch on the code).
///
/// `@MainActor` because the registration ceremony (`PasskeyProvider`) is
/// main-actor isolated; kept explicit rather than forcing a false `Sendable`.
@MainActor
public struct OwnerPasskeyEnrollmentOrchestrator {
    /// The registration (create) step. Production wraps a `PasskeyProvider`; tests
    /// inject a closure (no live `ASAuthorization`).
    public typealias Register =
        @MainActor (OwnerPasskeyRegistrationRequest) async throws -> OwnerPasskeyAttestation

    private let client: OwnerPasskeyEnrollmentClient
    private let register: Register

    /// Production initializer: the ceremony runs on the given platform provider.
    public init(client: OwnerPasskeyEnrollmentClient, provider: PasskeyProvider) {
        self.client = client
        self.register = { request in try await provider.register(request) }
    }

    /// Designated initializer with an injectable registration step. `internal` —
    /// the seam is reachable only via `@testable import`, never public API.
    init(client: OwnerPasskeyEnrollmentClient, register: @escaping Register) {
        self.client = client
        self.register = register
    }

    /// Runs the full first-enrollment ceremony: fetch the creation options, create
    /// the platform passkey, and submit the attestation. Returns the enrollment
    /// result (the new credential id + active credential count).
    @discardableResult
    public func enroll() async throws -> OwnerPasskeyEnrollmentResult {
        let startResponse = try await client.start()
        let request = try OwnerPasskeyEnrollmentClient.registrationRequest(from: startResponse)
        let attestation = try await register(request)
        let credential = OwnerPasskeyEnrollmentClient.credential(from: attestation)
        return try await client.finish(
            challengeID: startResponse.challengeID,
            credential: credential
        )
    }
}
#endif
