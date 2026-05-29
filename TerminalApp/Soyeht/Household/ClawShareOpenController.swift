import Foundation
import SoyehtCore
import os

/// Production `ClawShareDataPlaneClientFactory`. Returns the real
/// Rust-backed `ClawShareBridgeDataPlaneClient` (via the bridge-gated
/// `makeClawShareDataPlaneClient()`). **There is no fake here** — the only
/// fake client lives in the test targets. This is the single seam the
/// `ClawShareOpenCoordinator` uses to construct a session, so wiring it to
/// the real bridge is what keeps the product path honest.
struct ProductionClawShareDataPlaneClientFactory: ClawShareDataPlaneClientFactory {
    func makeClient() -> any ClawShareDataPlaneClient {
        makeClawShareDataPlaneClient()
    }
}

/// One launchable interactive session. Identifiable so SwiftUI can present
/// the terminal via `.fullScreenCover(item:)`; carries the already
/// credential-loaded + session-started client the coordinator handed back.
struct ClawShareTerminalLaunch: Identifiable {
    let id = UUID()
    let client: any ClawShareDataPlaneClient
    let displayName: String
}

/// App-side driver for the real "Open" gate.
///
/// On an accepted share it assembles `ClawShareOpenInputs` from the
/// credential + the operator-staged engine endpoint, signs the
/// proof-of-possession token with the Secure-Enclave guest identity, dials
/// the real bridge client, and only flips `canOpen` once the session reaches
/// `.interactiveReady`. Tapping Open hands the live client to a
/// `ClawShareTerminalViewController`.
///
/// Honest gating: if no endpoint is staged (the default today, until the
/// Nostr invite carries a reachable engine address), `prepare` is a no-op
/// and `canOpen` stays false — the sheet shows "almost ready", never a fake
/// Open. The endpoint is staged operationally (and, for the on-device smoke,
/// via a DEBUG-only deep link — see `DebugClawShareEndpointStager`).
@MainActor
final class ClawShareOpenController: ObservableObject {
    /// Published so the SwiftUI sheet can reveal Open exactly at `.openable`.
    @Published private(set) var phase: ClawShareOpenCoordinator.Phase = .unavailable(reason: "idle")
    /// Non-nil drives `.fullScreenCover` to present the terminal.
    @Published var launch: ClawShareTerminalLaunch?

    private let factory: any ClawShareDataPlaneClientFactory
    private let injectedSigner: (any ClawShareSessionTokenSigning)?
    private let identityProvider: any ClawShareGuestIdentityProvider
    private let endpointProvider: @Sendable () -> ClawShareDataPlaneEndpoint?
    private let logger = Logger(subsystem: "com.soyeht.mobile.clawshare", category: "open-controller")

    /// The coordinator that reached `.openable` for the current attempt;
    /// holds the live client handed to the terminal on Open.
    private var liveCoordinator: ClawShareOpenCoordinator?

    var canOpen: Bool {
        if case .openable = phase { return true }
        return false
    }

    /// Production: real bridge factory + SE guest identity + App-Group staged
    /// endpoint. Tests inject a fake factory + stub signer + fixed endpoint.
    /// When `signer` is nil the token signer is built from the SE identity on
    /// `prepare` (keeps the enclave call off init / off the simulator).
    init(
        identityProvider: any ClawShareGuestIdentityProvider,
        factory: any ClawShareDataPlaneClientFactory = ProductionClawShareDataPlaneClientFactory(),
        signer: (any ClawShareSessionTokenSigning)? = nil,
        endpointProvider: @escaping @Sendable () -> ClawShareDataPlaneEndpoint? = ClawShareOpenController.appGroupEndpoint
    ) {
        self.identityProvider = identityProvider
        self.factory = factory
        self.injectedSigner = signer
        self.endpointProvider = endpointProvider
    }

    /// Bring the session up to the open gate for an accepted share. No-op
    /// (stays unavailable) when the endpoint isn't staged — never dials,
    /// never shows a fake Open.
    func prepare(credential: GuestCredential, nowUnix: UInt64 = UInt64(Date().timeIntervalSince1970)) async {
        guard let inputs = ClawShareOpenInputs.fromAcceptedShare(
            credentialCBOR: ClawShareCodec.encode(credential),
            clawId: credential.clawId,
            endpoint: endpointProvider()
        ) else {
            phase = .unavailable(reason: "endpoint-not-staged")
            liveCoordinator = nil
            logger.info("open_prepare_skipped endpoint not staged claw=\(credential.clawId, privacy: .public)")
            return
        }

        let signer: any ClawShareSessionTokenSigning
        if let injectedSigner {
            signer = injectedSigner
        } else {
            do {
                signer = ClawShareGuestIdentitySigner(guestIdentity: try identityProvider.create())
            } catch {
                phase = .failed(reason: "identity-unavailable")
                liveCoordinator = nil
                logger.error("open_identity_failed \(String(describing: error), privacy: .public)")
                return
            }
        }

        let coord = ClawShareOpenCoordinator(factory: factory, signer: signer)
        liveCoordinator = coord
        let result = await coord.bringUp(inputs, nowUnix: nowUnix)
        phase = result
        logger.info("open_prepare_phase \(String(describing: result), privacy: .public)")
    }

    /// Present the terminal for the live, authenticated session. Effective
    /// only when `canOpen`; otherwise it does nothing (no client to hand out).
    func open(displayName: String) async {
        guard let coord = liveCoordinator, let client = await coord.startedClient() else {
            logger.error("open_tapped_without_client phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        launch = ClawShareTerminalLaunch(client: client, displayName: displayName)
    }

    /// The terminal closed (clean exit, drop, or user dismiss). Clear the
    /// launch so the gate can be re-entered from the share.
    func terminalClosed() {
        launch = nil
    }

    /// Read the operator-staged engine endpoint from the App-Group store.
    private static let appGroupEndpoint: @Sendable () -> ClawShareDataPlaneEndpoint? = {
        guard let store = FileSystemClawShareSharedStore.appGroup(),
              let staged = try? store.loadEndpoint() else { return nil }
        return ClawShareDataPlaneEndpoint(host: staged.host, port: staged.port)
    }
}
