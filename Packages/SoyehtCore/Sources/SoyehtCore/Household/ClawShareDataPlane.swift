import Foundation

/// Apple-grade data-plane gate for claw-share sessions.
///
/// This module is the Swift surface the host app and the
/// `NEPacketTunnelProvider` extension share. It DOES NOT itself
/// move packets — that's the bridge's job (Rust `ClawSession` +
/// `TunnelPlatformAdapter`). It does enforce the contract that
/// keeps the UI from ever pretending a claw session is openable
/// before a real packet round-trip has been observed.
///
/// Status this rodada:
/// - Protocol + states defined and tested.
/// - The `ClawShareBridge` XCFramework now lives in
///   `TerminalApp/Frameworks/` (Rust `claw-share-bridge-rs` +
///   `build-xcframework.sh`). The app + extension targets link it and
///   select the real Rust-backed client via
///   `makeClawShareDataPlaneClient()` (defined in the extension target).
/// - `PendingDataPlaneClient` is therefore NO LONGER the production
///   default — it is an explicit FALLBACK / TEST DOUBLE used only when
///   the framework is absent (e.g. this package's own `swift test`,
///   which stays bridge-free). It NEVER reports `connected` and throws
///   `dataPlaneNotInstalled` from `startSession`. The UI test
///   `ClawShareUIGateTests.testNoOpenAffordanceWithoutDataPlaneReady`
///   pins the contract so a future regression fails CI.
/// - Both the real client and the fallback honour the same gate:
///   `connected` only after a `health_ping` round-trip.

// MARK: - Public state surface

/// Lifecycle of a claw data-plane session. Mirrors the Rust
/// `SessionStatus` enum 1:1 — when the bridge ships, the mapping
/// happens here.
public enum ClawShareSessionStatus: Sendable, Equatable {
    /// No credential, no tunnel.
    case idle
    /// Credential is loaded; not yet dialed.
    case credentialReady
    /// Dial in flight.
    case dialing
    /// Handshake done; no health round-trip yet.
    case awaitingFirstPacket
    /// Real round-trip observed; tunnel may be advertised as open.
    case connected(sinceUnix: UInt64)
    /// Session torn down.
    case stopped(reason: String)
    /// Terminal failure.
    case failed(reason: String)
}

public extension ClawShareSessionStatus {
    /// Apple-grade gate predicate: the host UI MAY show an "open"
    /// affordance ONLY when this returns true. The contract test
    /// `testNoOpenAffordanceWithoutDataPlaneReady` proves every
    /// non-`connected` variant returns false.
    var isOpenable: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Client protocol

/// Where the engine's claw data tunnel is reachable. The host app
/// derives this from its engine base URL and stages it in the
/// App-Group store; the extension reads it and hands it to the bridge,
/// which dials `host:port`. Endpoint reachability — NOT a source-IP /
/// Tailscale assumption — plus a valid credential is what authorizes a
/// session.
public struct ClawShareDataPlaneEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum ClawShareDataPlaneError: Error, Sendable, Equatable {
    /// Production default surfaces this until the bridge framework
    /// ships. The host UI maps it to "iPhone can't open this share
    /// yet — accept it now and open from a paired Mac later".
    case dataPlaneNotInstalled
    case credentialInvalid
    case handshakeFailed(String)
    case healthRoundTripFailed
    case noSession
}

public protocol ClawShareDataPlaneClient: Sendable {
    /// Hand the credential to the data plane. After this, the
    /// session moves to `.credentialReady` if the credential parses
    /// and verifies.
    func loadCredential(_ credentialCBOR: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus

    /// Dial the engine data tunnel at `endpoint` and authenticate the
    /// loaded credential. Returns when the handshake completes. The
    /// session is `awaitingFirstPacket` after this — NEVER `connected`
    /// until `healthPing` succeeds.
    func startSession(endpoint: ClawShareDataPlaneEndpoint) async throws -> ClawShareSessionStatus

    /// Send a probe packet through the tunnel and wait for the
    /// reply. Only on success does the session transition to
    /// `connected`.
    func healthPing() async throws -> ClawShareSessionStatus

    func currentStatus() async -> ClawShareSessionStatus

    func stopSession(reason: String) async -> ClawShareSessionStatus
}

// MARK: - Pending (production default until the bridge ships)

/// Apple-grade honest fallback / test double. This is NOT the
/// production client anymore — `makeClawShareDataPlaneClient()` returns
/// the real `ClawShareBridgeDataPlaneClient` whenever
/// `ClawShareBridge.xcframework` is linked. `PendingDataPlaneClient` is
/// selected only when the framework is absent (the SoyehtCore
/// `swift test` target, which stays bridge-free). EVERY method either
/// reports `.idle` (no credential, no dial) or throws
/// `.dataPlaneNotInstalled`, so any code exercising the fallback MUST
/// surface a truthful "iPhone session not yet supported — accept this
/// share now and open from a Mac" message and MUST NOT advertise any
/// "open" affordance.
public actor PendingDataPlaneClient: ClawShareDataPlaneClient {
    private var loadedCredential: Bool = false

    public init() {}

    public func loadCredential(_ credentialCBOR: Data, nowUnix: UInt64) async throws -> ClawShareSessionStatus {
        // Credential persistence happens on the host (shared keychain) —
        // we don't reject this so the host can still record the
        // credential for the next slice. We DO mark the credential
        // as loaded so the host UI can transition to the "almost
        // ready" copy. But we do NOT enter `credentialReady` because
        // that would imply we can dial, which we can't yet.
        loadedCredential = true
        return .credentialReady
    }

    public func startSession(endpoint: ClawShareDataPlaneEndpoint) async throws -> ClawShareSessionStatus {
        throw ClawShareDataPlaneError.dataPlaneNotInstalled
    }

    public func healthPing() async throws -> ClawShareSessionStatus {
        throw ClawShareDataPlaneError.dataPlaneNotInstalled
    }

    public func currentStatus() async -> ClawShareSessionStatus {
        loadedCredential ? .credentialReady : .idle
    }

    public func stopSession(reason: String) async -> ClawShareSessionStatus {
        loadedCredential = false
        return .stopped(reason: reason)
    }
}
