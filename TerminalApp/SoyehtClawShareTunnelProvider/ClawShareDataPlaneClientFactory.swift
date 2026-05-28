import Foundation
import SoyehtCore

#if canImport(ClawShareBridge)
import ClawShareBridge

/// Production data-plane client backed by the real Rust
/// `ClawShareBridge` (`ClawSession`). Compiled only into targets that
/// link `ClawShareBridge.xcframework`; the `#if canImport` guard keeps
/// the `SoyehtCore` SwiftPM module (and its `swift test`) bridge-free.
///
/// Round 14: this is now a FULL data-plane client. `loadCredential`
/// decodes + verifies the credential in Rust; `startSession(endpoint:)`
/// dials the engine's claw data tunnel over TCP and authenticates the
/// credential; `healthPing` runs a real echo round-trip. `Connected` is
/// returned only after a byte-exact echo — the bridge enforces the
/// Apple-grade gate; this client just maps the types.
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

    func startSession(endpoint: ClawShareDataPlaneEndpoint) async throws -> ClawShareStartOutcome {
        do {
            let outcome = try await session.startSession(
                config: DataPlaneConfig(host: endpoint.host, port: endpoint.port)
            )
            return ClawShareStartOutcome(
                meshIPv6: outcome.meshIpv6,
                mtu: outcome.mtu,
                sessionId: outcome.sessionId,
                status: Self.map(outcome.status)
            )
        } catch let error as BridgeError {
            throw Self.map(error)
        }
    }

    func healthPing() async throws -> ClawShareSessionStatus {
        do {
            return Self.map(try await session.healthPing())
        } catch let error as BridgeError {
            throw Self.map(error)
        }
    }

    func verifyPacketPath() async throws -> ClawShareSessionStatus {
        do {
            return Self.map(try await session.verifyPacketPath())
        } catch let error as BridgeError {
            throw Self.map(error)
        }
    }

    func sendPacket(_ packet: Data) async throws {
        do {
            try await session.sendPacket(packet: packet)
        } catch let error as BridgeError {
            throw Self.map(error)
        }
    }

    func receivePacket() async throws -> Data {
        do {
            return try await session.receivePacket()
        } catch let error as BridgeError {
            throw Self.map(error)
        }
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
        case .packetVerified(let since):  return .packetVerified(sinceUnix: since)
        case .stopped(let reason):        return .stopped(reason: reason)
        case .failed(let reason):         return .failed(reason: reason)
        }
    }

    private static func map(_ error: BridgeError) -> ClawShareDataPlaneError {
        switch error {
        case .CredentialDecode, .CredentialInvalid: return .credentialInvalid
        case .HandshakeFailed(let message):         return .handshakeFailed(message)
        case .HealthRoundTripFailed:                return .healthRoundTripFailed
        case .PacketRoundTripFailed:                return .healthRoundTripFailed
        case .NoSession:                            return .noSession
        case .TransportFailed(let message):         return .handshakeFailed(message)
        case .Internal:                             return .dataPlaneNotInstalled
        }
    }
}
#endif

/// Selects the production claw-share data-plane client.
///
/// When `ClawShareBridge.xcframework` is linked — the host app and the
/// `SoyehtClawShareTunnelProvider` extension both do — the real
/// Rust-backed `ClawShareBridgeDataPlaneClient` is returned. Otherwise
/// (e.g. a SoyehtCore-only `swift test`, or any target that does not
/// embed the framework) `PendingDataPlaneClient` is the explicit,
/// honest fallback.
func makeClawShareDataPlaneClient() -> any ClawShareDataPlaneClient {
    #if canImport(ClawShareBridge)
    return ClawShareBridgeDataPlaneClient()
    #else
    return PendingDataPlaneClient()
    #endif
}
