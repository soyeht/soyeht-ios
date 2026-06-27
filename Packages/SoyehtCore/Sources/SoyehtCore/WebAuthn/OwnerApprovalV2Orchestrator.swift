#if canImport(AuthenticationServices)
import Foundation

/// Headless coordinator for the owner approval-v2 ceremony (SPM logic; no UI,
/// no app-target).
///
/// Drives: `client.start(cursor:)` → platform passkey assertion over the
/// server's OPAQUE challenge → submit the signed `OwnerApprovalV2Finish`
/// envelope via `client.approveV2(cursor:finish:)`.
///
/// There is deliberately NO client-side `challenge == context.challengeDigest()`
/// check: the WebAuthn challenge in the start response is the server's RANDOM
/// nonce (from `webauthn-rs`), not the context digest, and the operation binding
/// is enforced server-side (`challenge_id → context_binding → require_context`).
/// So the orchestrator forwards the challenge byte-for-byte and echoes the
/// server's `context` unchanged. "What you see is what you sign" is a UI-layer
/// concern (the screens present `startResponse.context` before the gesture) — it
/// is NOT a cryptographic equality here.
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

    /// Runs a full approval-v2 ceremony for the pending operation at `cursor`:
    /// start → assert (opaque challenge) → submit the signed envelope.
    ///
    /// Fail-closed: any error propagates unchanged and aborts before the next
    /// step — a cancelled/failed assertion never reaches `approveV2`, and a
    /// `start` reject never reaches the ceremony. Server rejects surface as the
    /// generic `BootstrapError` (no reason inference, no branch on the code).
    public func approve(cursor: UInt64) async throws {
        let startResponse = try await client.start(cursor: cursor)

        // Forward the server's options verbatim. The challenge is OPAQUE (the
        // server's random nonce) — never recomputed, substituted, or compared.
        let assertionRequest = OwnerPasskeyAssertionRequest(
            relyingPartyIdentifier: startResponse.relyingPartyIdentifier,
            challenge: startResponse.challenge,
            allowedCredentialIDs: startResponse.allowedCredentialIDs,
            userVerification: startResponse.userVerification
        )
        let assertion = try await authenticate(assertionRequest)

        // Echo the server's trusted context EXACTLY (no re-derivation); the
        // server re-checks it against its stored binding on `/approve`.
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
        try await client.approveV2(cursor: cursor, finish: finish)
    }
}
#endif
