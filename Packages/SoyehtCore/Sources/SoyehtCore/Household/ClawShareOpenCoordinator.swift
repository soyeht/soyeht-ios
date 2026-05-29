import Foundation
import os

/// Signs the session proof-of-possession token. Prod conforms via the
/// Secure-Enclave guest identity (`ClawShareSessionTokenSigner` +
/// `SecureEnclaveClawShareGuestIdentity`); tests inject a stub. Kept as a
/// protocol so `SoyehtCore` stays free of `Security`/SE specifics and the
/// coordinator is unit-testable without an enclave.
public protocol ClawShareSessionTokenSigning: Sendable {
    /// Sign `(session_id, credential_hash(credentialCBOR), endpoint,
    /// target_id, nonce, expires_at)` with the guest device key.
    func signedToken(
        sessionId: String,
        credentialCBOR: Data,
        endpoint: String,
        targetId: String,
        nonce: Data,
        expiresAtUnix: UInt64
    ) throws -> Data
}

/// Builds the production data-plane client. Prod returns the real
/// Rust-backed `ClawShareBridgeDataPlaneClient` (in the app/extension where
/// `ClawShareBridge` is linked); tests inject a fake. **The fake client must
/// never appear on the product path** — `makeClient()` here is the only
/// construction seam, and prod wires it to the real bridge.
public protocol ClawShareDataPlaneClientFactory: Sendable {
    func makeClient() -> any ClawShareDataPlaneClient
}

/// Everything the coordinator needs to open a real claw session. Sourced by
/// the host from the accepted share (credential), the staged engine endpoint,
/// and the offer's claw id. If any field is missing/empty the coordinator
/// refuses to open — the UI shows no "Open".
public struct ClawShareOpenInputs: Sendable, Equatable {
    public let credentialCBOR: Data
    public let endpoint: ClawShareDataPlaneEndpoint
    public let targetClawId: String

    public init(credentialCBOR: Data, endpoint: ClawShareDataPlaneEndpoint, targetClawId: String) {
        self.credentialCBOR = credentialCBOR
        self.endpoint = endpoint
        self.targetClawId = targetClawId
    }

    /// All real dependencies present (no empty credential / host / claw id).
    public var isComplete: Bool {
        !credentialCBOR.isEmpty && !endpoint.host.isEmpty && endpoint.port != 0 && !targetClawId.isEmpty
    }

    /// Assemble inputs from an accepted share. Returns `nil` when the engine
    /// endpoint hasn't been staged yet (the host then shows NO "Open" — an
    /// honest "almost ready", never a fake affordance that dials nothing).
    /// The credential bytes are the exact CBOR the engine verifies, and the
    /// target is the claw the credential is bound to — never operator input.
    public static func fromAcceptedShare(
        credentialCBOR: Data,
        clawId: String,
        endpoint: ClawShareDataPlaneEndpoint?
    ) -> ClawShareOpenInputs? {
        guard let endpoint else { return nil }
        let inputs = ClawShareOpenInputs(
            credentialCBOR: credentialCBOR,
            endpoint: endpoint,
            targetClawId: clawId
        )
        return inputs.isComplete ? inputs : nil
    }
}

/// Drives the real "Open" gate: from an accepted share, sign the PoP token,
/// dial + authenticate the real client, and only report `.openable` once the
/// session reaches `.interactiveReady`. The host shows the "Open" affordance
/// exactly when `canOpen` is true, and on tap hands `startedClient()` to a
/// `ClawShareTerminalViewController`.
///
/// Token TTL is short (`tokenTTLSeconds`) and the nonce is single-use, so a
/// token leaked from the App Group is useless after a couple of minutes / one
/// use (the engine's `ReplayGuard` rejects re-use).
public actor ClawShareOpenCoordinator {
    public enum Phase: Sendable, Equatable {
        /// No attempt yet, or a dependency is missing → no "Open".
        case unavailable(reason: String)
        case connecting
        /// Live interactive session — the ONLY phase that shows "Open".
        case openable(sinceUnix: UInt64)
        case failed(reason: String)
    }

    /// Max token lifetime — well under the engine's 300 s ceiling.
    public static let tokenTTLSeconds: UInt64 = 120

    private let factory: any ClawShareDataPlaneClientFactory
    private let signer: any ClawShareSessionTokenSigning
    private let logger = Logger(subsystem: "com.soyeht.mobile.clawshare", category: "open-coordinator")

    private var phase: Phase = .unavailable(reason: "idle")
    private var client: (any ClawShareDataPlaneClient)?

    public init(factory: any ClawShareDataPlaneClientFactory, signer: any ClawShareSessionTokenSigning) {
        self.factory = factory
        self.signer = signer
    }

    public func currentPhase() -> Phase { phase }

    /// Whether the host may show "Open".
    public var canOpen: Bool {
        if case .openable = phase { return true }
        return false
    }

    /// The authenticated, interactive client to hand to the terminal VC.
    /// Non-nil only after `bringUp` reached `.openable`.
    public func startedClient() -> (any ClawShareDataPlaneClient)? {
        guard case .openable = phase else { return nil }
        return client
    }

    /// Bring the session up to the open gate. Refuses (→ `.unavailable`) if a
    /// real dependency is missing; never constructs a session in that case.
    /// `nonce` is injectable for tests; prod passes a fresh CSPRNG value.
    @discardableResult
    public func bringUp(_ inputs: ClawShareOpenInputs, nowUnix: UInt64, nonce: Data? = nil) async -> Phase {
        guard inputs.isComplete else {
            phase = .unavailable(reason: "missing-dependency")
            logger.error("open_refused missing dependency")
            return phase
        }
        phase = .connecting
        let client = factory.makeClient()
        self.client = client

        let endpointString = "\(inputs.endpoint.host):\(inputs.endpoint.port)"
        let sessionId = "sess-\(UUID().uuidString.prefix(12))"
        let useNonce = nonce ?? Self.freshNonce()
        let expiresAt = nowUnix + Self.tokenTTLSeconds

        let tokenCBOR: Data
        do {
            tokenCBOR = try signer.signedToken(
                sessionId: sessionId,
                credentialCBOR: inputs.credentialCBOR,
                endpoint: endpointString,
                targetId: inputs.targetClawId,
                nonce: useNonce,
                expiresAtUnix: expiresAt
            )
        } catch {
            phase = .failed(reason: "token-signing-failed")
            self.client = nil
            logger.error("open_token_sign_failed \(String(describing: error), privacy: .public)")
            return phase
        }

        do {
            _ = try await client.loadCredential(inputs.credentialCBOR, nowUnix: nowUnix)
            _ = try await client.startSession(endpoint: inputs.endpoint, sessionToken: tokenCBOR)
            _ = try await client.healthPing()
            let opened = try await client.openStream()
            guard case .interactiveReady(let since) = opened else {
                phase = .failed(reason: "not-interactive")
                self.client = nil
                return phase
            }
            phase = .openable(sinceUnix: since)
            return phase
        } catch {
            phase = .failed(reason: Self.failureReason(error))
            self.client = nil
            logger.error("open_bringup_failed \(String(describing: error), privacy: .public)")
            return phase
        }
    }

    private static func failureReason(_ error: Error) -> String {
        switch error {
        case ClawShareDataPlaneError.dataPlaneNotInstalled: return "data-plane-unavailable"
        case ClawShareDataPlaneError.credentialInvalid: return "credential-invalid"
        case ClawShareDataPlaneError.handshakeFailed: return "handshake-failed"
        default: return "transport-failed"
        }
    }

    private static func freshNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var gen = SystemRandomNumberGenerator()
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: .min ... .max, using: &gen) }
        return Data(bytes)
    }
}
