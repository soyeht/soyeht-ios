#if canImport(AuthenticationServices)
import Foundation

/// A prepared approval-v2 ceremony: the server `start` result bound to the
/// `cursor` it belongs to.
///
/// Produced by ``OwnerApprovalV2Orchestrator/prepare(cursor:)`` so the UI can
/// render `startResponse.context` for the owner to review BEFORE the gesture,
/// then hand the SAME bundle to ``OwnerApprovalV2Orchestrator/confirm(_:)``.
/// Bundling the `cursor` with the reviewed `startResponse` keeps them tied — the
/// caller can't pass a different cursor after the review screen.
public struct PreparedOwnerApprovalV2: Sendable {
    public let cursor: UInt64
    public let startResponse: OwnerApprovalV2StartResponse

    public init(cursor: UInt64, startResponse: OwnerApprovalV2StartResponse) {
        self.cursor = cursor
        self.startResponse = startResponse
    }
}

/// Headless coordinator for the owner approval-v2 ceremony (SPM logic; no UI,
/// no app-target).
///
/// **Two-phase** so the UI can show the context-review screen between the network
/// `start` and the system passkey sheet:
/// - `prepare(cursor:)` → `start` only, returns the bound `PreparedOwnerApprovalV2`
///   (the screen renders `startResponse.context`);
/// - `confirm(_:)` → platform passkey assertion over the server's OPAQUE
///   challenge → submit the signed `OwnerApprovalV2Finish`.
/// `approve(cursor:)` is a convenience single-shot = prepare → confirm (no review
/// screen; behavior identical to the original single-shot).
///
/// There is deliberately NO client-side `challenge == context.challengeDigest()`
/// check: the WebAuthn challenge is the server's RANDOM nonce (`webauthn-rs`), not
/// the context digest, and the operation binding is enforced server-side
/// (`challenge_id → context_binding → require_context`). So the orchestrator
/// forwards the challenge byte-for-byte and echoes the server `context` unchanged.
/// "What you see is what you sign" is a UI-layer concern, not a crypto equality.
///
/// `@MainActor` because the assertion ceremony (`PasskeyProvider`) is main-actor
/// isolated; kept explicit rather than forcing a false `Sendable`.
@MainActor
public struct OwnerApprovalV2Orchestrator {
    /// The assertion step. Production wraps a `PasskeyProvider`; tests inject a
    /// closure (no live `ASAuthorization`).
    public typealias Authenticate =
        @MainActor (OwnerPasskeyAssertionRequest) async throws -> OwnerPasskeyAssertion

    private let client: OwnerApprovalV2Client
    private let authenticate: Authenticate

    /// Production initializer: the assertion runs on the given platform provider.
    public init(client: OwnerApprovalV2Client, provider: PasskeyProvider) {
        self.client = client
        self.authenticate = { request in try await provider.authenticate(request) }
    }

    /// Designated initializer with an injectable assertion step. `internal` — the
    /// seam is reachable only via `@testable import`, never public API.
    init(client: OwnerApprovalV2Client, authenticate: @escaping Authenticate) {
        self.client = client
        self.authenticate = authenticate
    }

    /// Phase 1 — fetch the server's start response for the pending operation at
    /// `cursor`. Performs ONLY the network `start`: no assertion, no approve. The
    /// returned bundle carries the `cursor` so `confirm(_:)` posts to the right
    /// path. The UI renders `startResponse.context` before the gesture.
    public func prepare(cursor: UInt64) async throws -> PreparedOwnerApprovalV2 {
        let startResponse = try await client.start(cursor: cursor)
        return PreparedOwnerApprovalV2(cursor: cursor, startResponse: startResponse)
    }

    /// Phase 2 — assert over the prepared (opaque) challenge and submit the signed
    /// envelope, posting to the `cursor` carried by the bundle.
    ///
    /// Fail-closed: any error propagates unchanged and aborts before the next step
    /// — a cancelled/failed assertion never reaches `approveV2`. Server rejects
    /// surface as the generic `BootstrapError` (no reason inference / no branch).
    public func confirm(_ prepared: PreparedOwnerApprovalV2) async throws {
        let startResponse = prepared.startResponse

        // Forward the server's options verbatim. The challenge is OPAQUE (the
        // server's random nonce) — never recomputed, substituted, or compared.
        let assertionRequest = OwnerPasskeyAssertionRequest(
            relyingPartyIdentifier: startResponse.relyingPartyIdentifier,
            challenge: startResponse.challenge,
            allowedCredentialIDs: startResponse.allowedCredentialIDs,
            userVerification: startResponse.userVerification
        )
        let assertion = try await authenticate(assertionRequest)

        // Echo the server's trusted context EXACTLY (no re-derivation).
        let approval = OwnerApprovalV2(
            context: startResponse.context,
            credentialID: assertion.credentialID,
            authenticatorData: assertion.authenticatorData,
            clientDataJSON: assertion.clientDataJSON,
            signature: assertion.signature,
            userHandle: assertion.userHandle
        )
        let finish = OwnerApprovalV2Finish(
            challengeID: startResponse.challengeID,
            approval: approval
        )
        try await client.approveV2(cursor: prepared.cursor, finish: finish)
    }

    /// Convenience single-shot = `prepare` → `confirm` (no review screen).
    /// Behavior identical to the original single-shot `approve(cursor:)`.
    public func approve(cursor: UInt64) async throws {
        let prepared = try await prepare(cursor: cursor)
        try await confirm(prepared)
    }
}
#endif
