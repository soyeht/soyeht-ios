import Foundation
import SoyehtCore

#if canImport(ClawShareBridge)
import ClawShareBridge

/// Production data-plane client backed by the real Rust
/// `ClawShareBridge` (`ClawSession`). Compiled only into targets that
/// link `ClawShareBridge.xcframework`; the `#if canImport` guard keeps
/// the `SoyehtCore` SwiftPM module (and its `swift test`) bridge-free.
///
/// What the exported UniFFI surface lets this client do TODAY:
/// - `loadCredential` — REAL canonical-CBOR decode + signature/expiry
///   verification inside Rust (`GuestCredential::verify`).
/// - `currentStatus` / `stopSession` — real session state.
///
/// What it CANNOT do yet: `startSession` / `healthPing`. Those Rust
/// methods are intentionally NOT `#[uniffi::export]`'d because they
/// require the `TunnelPlatformAdapter` FFI seam, which is unbuilt
/// (a `Vec<u8>`-per-packet UniFFI callback is too slow; the follow-up
/// slice introduces a foreign-trait adapter object). Until that seam
/// ships this client refuses to dial with a TYPED
/// `.dataPlaneNotInstalled` — the same Apple-grade gate as
/// `PendingDataPlaneClient`, but now with a real credential round-trip
/// behind it. **This is the exact next blocker.** No fake `connected`,
/// no crash, fully recoverable.
final class ClawShareBridgeDataPlaneClient: ClawShareDataPlaneClient, @unchecked Sendable {
    private let session = ClawSession()

    func loadCredential(_ credentialCBOR: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus {
        do {
            let status = try await session.loadCredential(
                credentialCbor: credentialCBOR,
                nowUnix: nowUnix
            )
            return Self.map(status)
        } catch let error as BridgeError {
            throw Self.map(error)
        }
    }

    func startSession() async throws -> ClawShareSessionStatus {
        // The platform adapter FFI seam is not exported yet, so the
        // bridge physically cannot move packets. Surface a typed,
        // recoverable error; the provider persists `.failed` and the
        // host UI renders the honest "open from a paired Mac" copy.
        throw ClawShareDataPlaneError.dataPlaneNotInstalled
    }

    func healthPing() async throws -> ClawShareSessionStatus {
        throw ClawShareDataPlaneError.dataPlaneNotInstalled
    }

    func currentStatus() async -> ClawShareSessionStatus {
        Self.map(await session.status())
    }

    func stopSession(reason: String) async -> ClawShareSessionStatus {
        Self.map(await session.stopSession(reason: reason))
    }

    private static func map(_ status: SessionStatus) -> ClawShareSessionStatus {
        switch status {
        case .idle:                       return .idle
        case .credentialReady:            return .credentialReady
        case .dialing:                    return .dialing
        case .awaitingFirstPacket:        return .awaitingFirstPacket
        case .connected(let since):       return .connected(sinceUnix: since)
        case .stopped(let reason):        return .stopped(reason: reason)
        case .failed(let reason):         return .failed(reason: reason)
        }
    }

    private static func map(_ error: BridgeError) -> ClawShareDataPlaneError {
        switch error {
        case .CredentialDecode, .CredentialInvalid: return .credentialInvalid
        case .HandshakeFailed(let message):         return .handshakeFailed(message)
        case .HealthRoundTripFailed:                return .healthRoundTripFailed
        case .NoSession:                            return .noSession
        case .AdapterMissing, .Internal:            return .dataPlaneNotInstalled
        }
    }
}
#endif

/// Selects the production claw-share data-plane client.
///
/// When `ClawShareBridge.xcframework` is linked — the host app and the
/// `SoyehtClawShareTunnelProvider` extension both do — the real
/// Rust-backed `ClawShareBridgeDataPlaneClient` is returned.
/// Otherwise (e.g. a SoyehtCore-only `swift test`, or any target that
/// does not embed the framework) `PendingDataPlaneClient` is the
/// explicit, honest fallback.
///
/// `PendingDataPlaneClient` is therefore NEVER the production default
/// when the bridge is present — it is a fallback / test double only.
func makeClawShareDataPlaneClient() -> any ClawShareDataPlaneClient {
    #if canImport(ClawShareBridge)
    return ClawShareBridgeDataPlaneClient()
    #else
    return PendingDataPlaneClient()
    #endif
}
