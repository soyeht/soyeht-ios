import Foundation

/// Receives an incoming `soyeht://claw-share/v1?e=<base64url-cbor>` deep
/// link, parses + verifies the invite shape (signature, expiry,
/// bindings), persists a pending claim record, and surfaces a typed
/// state to the UI layer.
///
/// Apple-grade gating contract: the router never advances past
/// `.acceptanceReady` without explicit user consent (the UI calls
/// `accept(_:)`) and never advances past `.acceptedAwaitingDataPlane`
/// while the data plane is absent. The "connected" state — terminal
/// session attachable — does not exist in this module today. The data
/// plane gate is the project-wide UniFFI/nvpn integration follow-up;
/// until that lands, the highest-level UI state the router can reach is
/// `.acceptedAwaitingDataPlane` and the host UI MUST surface that as
/// "preparing access — not yet connected".

public enum ClawShareRouterState: Sendable, Equatable {
    /// No invite in flight.
    case idle
    /// Deep link consumed; invite parsed + verified; awaiting user
    /// acceptance.
    case acceptanceReady(ClawShareInvite)
    /// User accepted; claim sent to engine (relay or HTTP); awaiting
    /// the credential ack. Persisted to disk so a relaunch resumes.
    case claimInFlight(ClawShareInvite)
    /// Engine returned a verified GuestCredential. The claim ceremony
    /// is complete from a control-plane perspective — but the data
    /// plane is NOT yet live; the host UI MUST gate any "open"
    /// action behind `.dataPlaneReady` (which this module never
    /// emits in the current iteration).
    case acceptedAwaitingDataPlane(GuestCredential, ClawShareTunnelHandle)
    /// Terminal error path. The UI surfaces a human-readable message
    /// and a single retry-from-scratch action (no silent retry).
    case failed(ClawShareError)
}

public enum ClawSharePendingPersistenceKey: String, Sendable {
    /// Single in-flight invite — the slice intentionally allows only
    /// one at a time. Multi-invite UI is a follow-up.
    case currentInvitePending = "com.soyeht.claw-share.invite.pending"
    /// The verified credential the friend holds after a successful
    /// claim. Persistent so a relaunch doesn't lose access.
    case currentCredential = "com.soyeht.claw-share.credential.current"
}

public protocol ClawSharePendingStore: Sendable {
    func savePendingInvite(_ data: Data) throws
    func loadPendingInvite() throws -> Data?
    func clearPendingInvite() throws
    func saveCredential(_ data: Data) throws
    func loadCredential() throws -> Data?
}

public struct UserDefaultsClawSharePendingStore: ClawSharePendingStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func savePendingInvite(_ data: Data) throws {
        defaults.set(data, forKey: ClawSharePendingPersistenceKey.currentInvitePending.rawValue)
    }

    public func loadPendingInvite() throws -> Data? {
        defaults.data(forKey: ClawSharePendingPersistenceKey.currentInvitePending.rawValue)
    }

    public func clearPendingInvite() throws {
        defaults.removeObject(forKey: ClawSharePendingPersistenceKey.currentInvitePending.rawValue)
    }

    public func saveCredential(_ data: Data) throws {
        defaults.set(data, forKey: ClawSharePendingPersistenceKey.currentCredential.rawValue)
    }

    public func loadCredential() throws -> Data? {
        defaults.data(forKey: ClawSharePendingPersistenceKey.currentCredential.rawValue)
    }
}

public actor ClawShareInviteRouter {
    private var current: ClawShareRouterState = .idle
    private let store: any ClawSharePendingStore
    private let now: @Sendable () -> Date

    public init(
        store: any ClawSharePendingStore = UserDefaultsClawSharePendingStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func currentState() -> ClawShareRouterState {
        current
    }

    /// Entry point for the AppDelegate's `scene(_:openURLContexts:)`.
    /// Returns true when the URL was consumed by this module; false
    /// when the URL is unrelated (so the caller can keep routing).
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard url.scheme == "soyeht", url.host == "claw-share" else {
            return false
        }
        do {
            let invite = try ClawShareCodec.decodeInviteURI(url.absoluteString)
            let nowUnix = UInt64(now().timeIntervalSince1970)
            if invite.expiresAt <= nowUnix {
                current = .failed(.inviteExpired)
                return true
            }
            // Persist so a relaunch picks up where the user left off
            // (e.g., they tapped the link in iMessage but immediately
            // backgrounded the app to confirm with the inviter).
            let cbor = ClawShareCodec.encode(invite)
            try? store.savePendingInvite(cbor)
            current = .acceptanceReady(invite)
        } catch {
            current = .failed(.inviteMalformed)
        }
        return true
    }

    /// Called by the UI after the user explicitly taps "Accept this
    /// share". This transitions to `.claimInFlight` and is the moment
    /// the network call should be issued by the caller. Returns the
    /// invite the UI should claim against, or nil if no acceptance is
    /// pending.
    public func accept() -> ClawShareInvite? {
        guard case .acceptanceReady(let invite) = current else {
            return nil
        }
        current = .claimInFlight(invite)
        return invite
    }

    /// Called by the caller after the network claim succeeds. The
    /// credential is persisted so future launches load it. Tunnel
    /// handle is held in-memory but NOT acted on by this module —
    /// the data plane gate keeps the user out of "open terminal"
    /// surfaces until the host wires a real tunnel.
    public func didReceiveAck(_ session: ClaimedSession) throws {
        let cred = ClawShareCodec.encode(session.credential)
        try store.saveCredential(cred)
        try? store.clearPendingInvite()
        current = .acceptedAwaitingDataPlane(session.credential, session.tunnel)
    }

    public func didFail(_ error: ClawShareError) {
        try? store.clearPendingInvite()
        current = .failed(error)
    }

    public func reset() {
        try? store.clearPendingInvite()
        current = .idle
    }
}
