#if canImport(AuthenticationServices)
import Foundation

/// A prepared AddCredential ceremony: the server start response whose context
/// can be reviewed before the two platform passkey gestures.
public struct PreparedOwnerWebauthnAddCredential: Sendable {
    public let startResponse: OwnerWebauthnAddCredentialStartResponse

    public init(startResponse: OwnerWebauthnAddCredentialStartResponse) {
        self.startResponse = startResponse
    }
}

/// Headless coordinator for AddCredential dual ceremony (SPM logic; no UI,
/// no app-target).
///
/// **Two-phase** so a future UI can render the server-derived AddCredential
/// context before any passkey gesture:
/// - `prepare()` -> start only, returning the bound start response;
/// - `confirm(_:)` -> active-owner assertion, new credential registration, then
///   submit the composite finish wrapper.
///
/// The assertion is attempted before registration so a cancelled active-owner
/// step-up cannot leave a newly created local passkey that the server never
/// commits. Both challenges are still server-bound and consumed only by finish.
///
/// There is no client-side recomputation of context, binding digest, or authority
/// head. The orchestrator echoes the server top-level context unchanged; the
/// engine remains authoritative for byte-equality and binding checks.
@MainActor
public struct OwnerWebauthnAddCredentialOrchestrator {
    public typealias Authenticate =
        @MainActor (OwnerPasskeyAssertionRequest) async throws -> OwnerPasskeyAssertion
    public typealias Register =
        @MainActor (OwnerPasskeyRegistrationRequest) async throws -> OwnerPasskeyAttestation

    private let client: OwnerWebauthnAddCredentialClient
    private let authenticate: Authenticate
    private let register: Register

    /// Production initializer: both ceremonies run on the given platform provider.
    public init(client: OwnerWebauthnAddCredentialClient, provider: PasskeyProvider) {
        self.client = client
        self.authenticate = { request in try await provider.authenticate(request) }
        self.register = { request in try await provider.register(request) }
    }

    /// Designated initializer with injectable ceremony steps. `internal` —
    /// reachable only via `@testable import`, never public API.
    init(
        client: OwnerWebauthnAddCredentialClient,
        authenticate: @escaping Authenticate,
        register: @escaping Register
    ) {
        self.client = client
        self.authenticate = authenticate
        self.register = register
    }

    /// Phase 1 — fetch the dual-ceremony start response. Performs no platform
    /// assertion, no registration, and no finish.
    public func prepare() async throws -> PreparedOwnerWebauthnAddCredential {
        let startResponse = try await client.start()
        return PreparedOwnerWebauthnAddCredential(startResponse: startResponse)
    }

    /// Phase 2 — run the active-owner assertion, create the new passkey, and
    /// submit both outputs in the server-provided AddCredential finish wrapper.
    ///
    /// Fail-closed: any error propagates unchanged and aborts before the next
    /// step. Server rejects surface as generic `BootstrapError`; no branch on the
    /// opaque reject reason.
    @discardableResult
    public func confirm(
        _ prepared: PreparedOwnerWebauthnAddCredential
    ) async throws -> OwnerWebauthnAddCredentialResult {
        let startResponse = prepared.startResponse

        let assertionRequest = OwnerWebauthnAddCredentialClient.assertionRequest(from: startResponse)
        let assertion = try await authenticate(assertionRequest)

        let registrationRequest = try OwnerWebauthnAddCredentialClient.registrationRequest(from: startResponse)
        let attestation = try await register(registrationRequest)

        let finish = OwnerWebauthnAddCredentialClient.finishRequest(
            from: startResponse,
            attestation: attestation,
            assertion: assertion
        )
        return try await client.finish(request: finish)
    }

    /// Convenience single-shot = `prepare` -> `confirm` (no review screen).
    @discardableResult
    public func addCredential() async throws -> OwnerWebauthnAddCredentialResult {
        let prepared = try await prepare()
        return try await confirm(prepared)
    }
}
#endif
