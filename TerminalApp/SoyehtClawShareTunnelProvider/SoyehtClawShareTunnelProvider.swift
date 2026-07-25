import Foundation
import NetworkExtension
import RelayStreamGuestFFI
import SoyehtCore
import os

/// Authenticated RelayStream `IpTunnel` Network Extension.
///
/// The host app prepares and Secure-Enclave-signs the short-lived auth request,
/// then passes it only in `startVPNTunnel(options:)`. This extension has no
/// private signing key and persists none of the start material.
final class SoyehtClawShareTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(
        subsystem: "com.soyeht.mobile.clawshare",
        category: "ip-tunnel-provider"
    )
    private var startTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var activeSession: RelayStreamGuestDataPlaneSession?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard startTask == nil, pumpTask == nil, activeSession == nil else {
            completionHandler(RelayStreamIPTunnelProviderError.alreadyRunning)
            return
        }

        startTask = Task {
            do {
                let session = try await beginSession(options: options)
                do {
                    try Task.checkCancellation()
                } catch {
                    try? await session.close()
                    throw error
                }
                activeSession = session
                startTask = nil
                startPacketPump(session: session)
                logger.info("relay_stream_ip_tunnel_started")
                completionHandler(nil)
            } catch {
                startTask = nil
                logger.error("relay_stream_ip_tunnel_start_failed")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with _: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        startTask?.cancel()
        startTask = nil
        pumpTask?.cancel()
        pumpTask = nil

        let session = activeSession
        activeSession = nil
        Task {
            if let session {
                try? await session.close()
            }
            logger.info("relay_stream_ip_tunnel_stopped")
            completionHandler()
        }
    }

    private func beginSession(
        options: [String: NSObject]?
    ) async throws -> RelayStreamGuestDataPlaneSession {
        guard let encoded = options?[RelayStreamGuestTunnelStartOptions.optionKey] as? Data else {
            throw RelayStreamIPTunnelProviderError.missingStartOptions
        }

        let nowUnix = UInt64(max(0, Date().timeIntervalSince1970))
        let startOptions = try RelayStreamGuestTunnelStartOptions.decode(
            encoded,
            nowUnix: nowUnix
        )
        let offer = try RelayStreamOfferContract.fromCanonicalBytes(startOptions.offerCbor)
        guard offer.canonicalBytes() == startOptions.offerCbor else {
            throw RelayStreamIPTunnelProviderError.nonCanonicalOffer
        }
        try offer.verifyRelayStreamIPTunnelGuest(
            expectedSignerPublicKey: startOptions.expectedOwnerPub,
            expectedGuestDevicePublicKey: startOptions.expectedGuestPub,
            nowUnix: nowUnix
        )
        guard startOptions.authMode == .offerPayload,
              startOptions.endpoint == offer.payload.relayEndpoint,
              startOptions.targetId == offer.payload.clawId,
              startOptions.authMaterialCbor == offer.payload.canonicalBytes(),
              startOptions.expiresAt <= offer.payload.notAfter
        else {
            throw RelayStreamIPTunnelProviderError.authBindingMismatch
        }

        let request = try startOptions.authSigningRequest()
        let session = try await RelayStreamGuestDataPlaneClient().connectPrepared(
            offerCbor: startOptions.offerCbor,
            expectedOwnerPub: startOptions.expectedOwnerPub,
            expectedGuestPub: startOptions.expectedGuestPub,
            request: request,
            signature: startOptions.signature,
            nowUnix: nowUnix,
            connectTimeoutMs: startOptions.connectTimeoutMs
        )

        do {
            let metadata = await session.metadata()
            try await applyNetworkSettings(metadata: metadata)
            return session
        } catch {
            try? await session.close()
            throw error
        }
    }

    private func applyNetworkSettings(
        metadata: RelayStreamGuestSessionMetadata
    ) async throws {
        guard let meshIPv4 = metadata.meshIpv4,
              metadata.meshIpv6 == nil
        else {
            throw RelayStreamIPTunnelProviderError.invalidAuthenticatedNetworkSettings
        }

        let settings: NEPacketTunnelNetworkSettings
        do {
            settings = try RelayStreamIPTunnelNetworkSettings.make(
                assignment: RelayStreamIPv4Assignment(
                    address: meshIPv4.addr,
                    prefixLength: meshIPv4.prefixLen,
                    peer: meshIPv4.peer
                ),
                mtu: metadata.mtu,
                sessionID: metadata.sessionId
            )
        } catch {
            throw RelayStreamIPTunnelProviderError.invalidAuthenticatedNetworkSettings
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startPacketPump(session: RelayStreamGuestDataPlaneSession) {
        let pump = RelayStreamIPPacketPump(
            flow: NEPacketTunnelFlowAdapter(packetFlow),
            session: RelayStreamGuestIPTunnelSessionAdapter(session: session)
        )
        pumpTask = Task {
            do {
                try await pump.run()
            } catch is CancellationError {
                return
            } catch {
                logger.error("relay_stream_ip_tunnel_packet_pump_failed")
                try? await session.close()
                activeSession = nil
                pumpTask = nil
                cancelTunnelWithError(error)
            }
        }
    }
}

private enum RelayStreamIPTunnelProviderError: Error, Sendable, Equatable {
    case alreadyRunning
    case missingStartOptions
    case nonCanonicalOffer
    case authBindingMismatch
    case invalidAuthenticatedNetworkSettings
}
