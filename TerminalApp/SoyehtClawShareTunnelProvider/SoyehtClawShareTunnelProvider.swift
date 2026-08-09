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
    /// All mutable lifecycle state lives here, never as properties on the
    /// provider. `startTunnel`/`stopTunnel` arrive as synchronous callbacks on
    /// NetworkExtension's queue, and their order is the only ordering the system
    /// guarantees; committing each intent SYNCHRONOUSLY at the callback keeps
    /// that order, instead of inheriting whatever order two unstructured tasks
    /// happen to be scheduled in.
    private let lifecycle = RelayStreamIPTunnelSessionMachine()

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        #if DEBUG
        if case .handled(let error) = M0bSmokeCheck.runIfRequested(options: options, logger: logger) {
            completionHandler(error)
            return
        }
        #endif

        // Claimed before anything is spawned, so a stop that arrives next is
        // ordered strictly after this claim.
        guard let epoch = lifecycle.begin() else {
            completionHandler(RelayStreamIPTunnelProviderError.alreadyRunning)
            return
        }

        // Strong capture, deliberately. `await self?.drive(...)` yields
        // `Task<()?, Never>`, which is not the `Task<Void, Never>` the machine
        // adopts — but the real reason is the contract, not the type: NE learns
        // the outcome ONLY through `completionHandler`, so a provider
        // deallocated mid-start would drop it and leave the system waiting.
        // The task is owned by the machine and cancelled by `stop()`, so the
        // reference is bounded by the start it is driving.
        let driver = Task {
            await self.drive(
                options: options,
                epoch: epoch,
                completionHandler: completionHandler
            )
        }
        // Adoption is epoch-checked: if a stop already landed, the machine
        // cancels this task rather than adopting it.
        lifecycle.adoptStartTask(driver, epoch: epoch)
    }

    override func stopTunnel(
        with _: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        // Teardown is committed SYNCHRONOUSLY, before the task that does the
        // closing exists. Deferring this into the task would let a concurrent
        // start observe an idle machine and resurrect the tunnel.
        let closing = lifecycle.stop()
        let logger = self.logger
        Task {
            await closing?.closeSession()
            logger.info("relay_stream_ip_tunnel_stopped")
            completionHandler()
        }
    }

    /// Connect, then install — and call `completionHandler` exactly once, on
    /// every path.
    private func drive(
        options: [String: NSObject]?,
        epoch: RelayStreamIPTunnelSessionMachine.Epoch,
        completionHandler: @escaping (Error?) -> Void
    ) async {
        let session: RelayStreamGuestDataPlaneSession
        do {
            session = try await beginSession(options: options)
        } catch {
            lifecycle.startFailed(epoch: epoch)
            logger.error("relay_stream_ip_tunnel_start_failed")
            completionHandler(error)
            return
        }

        // The lifecycle only needs "something closable", so it takes the wrapper
        // rather than the imported session type. The pump still captures the
        // CONCRETE session below.
        let outcome = lifecycle.activate(
            session: ClosableGuestSession(session: session),
            epoch: epoch
        ) {
            self.makePumpTask(session: session, epoch: epoch)
        }

        switch outcome {
        case .activated:
            logger.info("relay_stream_ip_tunnel_started")
            completionHandler(nil)
        case .superseded:
            // A stop won the race. This session was never pumped; closing it is
            // this caller's contract. Closed on the CONCRETE session, so the
            // teardown path does not depend on any protocol conformance.
            try? await session.close()
            logger.info("relay_stream_ip_tunnel_start_superseded")
            completionHandler(RelayStreamIPTunnelProviderError.stoppedDuringStart)
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

    /// Builds the pump task. Called by the machine while it still holds its
    /// lock, so the pump cannot observe a half-installed session — and its own
    /// cleanup, which reaches back into the machine, blocks until installation
    /// has published `.running`.
    private func makePumpTask(
        session: RelayStreamGuestDataPlaneSession,
        epoch: RelayStreamIPTunnelSessionMachine.Epoch
    ) -> Task<Void, Never> {
        let pump = RelayStreamIPPacketPump(
            flow: NEPacketTunnelFlowAdapter(packetFlow),
            session: RelayStreamGuestIPTunnelSessionAdapter(session: session)
        )
        return Task {
            do {
                try await pump.run()
            } catch is CancellationError {
                // Cancelled by `stop()`, which already owns the teardown.
                return
            } catch {
                // OWNERSHIP FIRST, EFFECTS SECOND. `nil` means a `stop()` (or a
                // newer generation) already took this session, so closing it
                // here would double-close, and raising the error here would
                // cancel a tunnel this failure has nothing to do with.
                guard let closing = self.lifecycle.pumpFailed(epoch: epoch) else {
                    return
                }
                self.logger.error("relay_stream_ip_tunnel_packet_pump_failed")
                // No suspension is allowed between claiming this failure and
                // emitting its system-level cancel. A concurrent `stop()` keeps
                // the machine fenced in `.failing`, so a new generation cannot
                // start and receive this old cancel.
                self.cancelTunnelWithError(error)
                self.lifecycle.failureReported(epoch: epoch)
                // The cancel is already emitted and the old generation is
                // released. Closing its concrete session may now suspend
                // without delaying the system notification or threatening a
                // later generation.
                await closing.closeSession()
                return
            }
            // Same rule on the clean path: close only what was handed over.
            guard let closing = self.lifecycle.pumpFinished(epoch: epoch) else {
                return
            }
            await closing.closeSession()
        }
    }
}

/// Adapts a data-plane session to the lifecycle's closable contract.
///
/// A retroactive conformance of the imported `RelayStreamGuestDataPlaneSession`
/// to the imported `RelayStreamIPTunnelClosableSession` would be a conformance
/// this module owns for two types it does not — the case Swift warns about,
/// because whichever module declares it later wins and the choice is invisible
/// here. A private wrapper keeps the adaptation local and unambiguous.
private struct ClosableGuestSession: RelayStreamIPTunnelClosableSession {
    let session: RelayStreamGuestDataPlaneSession

    func closeSession() async {
        try? await session.close()
    }
}

private enum RelayStreamIPTunnelProviderError: Error, Sendable, Equatable {
    case alreadyRunning
    case stoppedDuringStart
    case missingStartOptions
    case nonCanonicalOffer
    case authBindingMismatch
    case invalidAuthenticatedNetworkSettings
}
