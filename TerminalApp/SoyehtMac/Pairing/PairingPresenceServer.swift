import Darwin
import Foundation
import Network
import SoyehtCore
import os

private let presenceLogger = Logger(subsystem: "com.soyeht.mac", category: "presence")

/// App-level WebSocket server that accepts persistent presence connections
/// from paired iPhones and per-pane attach streams. Lifecycle is tied to the
/// Mac app itself — boots once in `AppDelegate.applicationDidFinishLaunching`,
/// stays up until termination.
///
/// Two NWListeners run in parallel because `NWProtocolWebSocket.setClientRequestHandler`
/// doesn't expose the request path to the handler; using separate ports per
/// route avoids hand-rolling an HTTP parser. Ports are persisted in
/// UserDefaults so clients can cache them between launches.
@MainActor
final class PairingPresenceServer {
    static let shared = PairingPresenceServer()

    /// Broadcast when any paired iPhone authenticates, disconnects, or
    /// starts/ends a pane-attach stream. Observers: `PaneViewController`
    /// (updates "Abrir no iPhone" button enabled state) and sidebar overlay
    /// (updates per-row `iphone` device badge). Using NotificationCenter
    /// instead of a single callback lets multiple observers coexist without
    /// the fragile previous-callback-chain pattern that used to break on
    /// view controller teardown order.
    static let membershipDidChangeNotification = Notification.Name("com.soyeht.mac.presenceMembershipDidChange")

    private enum DefaultsKey {
        static let presencePort = "com.soyeht.mac.presencePort"
        static let attachPort   = "com.soyeht.mac.attachPort"
    }

    private let queue = DispatchQueue(label: "com.soyeht.mac.presence-server", qos: .userInitiated)

    private var presenceListener: NWListener?
    private var attachListener: NWListener?

    /// Sessions keyed by their generated UUID. One per active WS connection.
    private var presenceSessions: [UUID: PresenceSession] = [:]
    private var attachSessions: [UUID: PaneStreamSession] = [:]

    private(set) var presencePort: UInt16?
    private(set) var attachPort: UInt16?

    /// Post `membershipDidChangeNotification` on every connect / disconnect /
    /// auth transition. Kept private so callers go through the server itself.
    private func broadcastMembershipChange() {
        NotificationCenter.default.post(name: Self.membershipDidChangeNotification, object: self)
    }

    // MARK: - Lifecycle

    func start() {
        guard presenceListener == nil, attachListener == nil else {
            presenceLogger.log("start_skipped already_running")
            return
        }

        do {
            presenceListener = try makeListener(
                preferredPort: UInt16(UserDefaults.standard.integer(forKey: DefaultsKey.presencePort))
            )
            attachListener = try makeListener(
                preferredPort: UInt16(UserDefaults.standard.integer(forKey: DefaultsKey.attachPort))
            )
        } catch {
            presenceLogger.error("listener_create_failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        presenceListener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handlePresenceListenerState(state)
            }
        }
        presenceListener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.acceptPresence(connection)
            }
        }

        attachListener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleAttachListenerState(state)
            }
        }
        attachListener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.acceptAttach(connection)
            }
        }

        presenceListener?.start(queue: queue)
        attachListener?.start(queue: queue)
    }

    func stop() {
        presenceLogger.log("server_stop presence=\(self.presenceSessions.count, privacy: .public) attach=\(self.attachSessions.count, privacy: .public)")
        for session in presenceSessions.values { session.cancel() }
        for session in attachSessions.values { session.cancel() }
        presenceSessions.removeAll()
        attachSessions.removeAll()
        presenceListener?.cancel()
        presenceListener = nil
        attachListener?.cancel()
        attachListener = nil
        presencePort = nil
        attachPort = nil
    }

    /// Returns true if any paired iPhone currently has an authenticated
    /// presence WS. Used by PaneViewController button state.
    var hasConnectedDevices: Bool {
        presenceSessions.values.contains(where: { $0.isAuthenticated })
    }

    /// Returns all authenticated device IDs currently connected, for the
    /// "Abrir no iPhone" multi-device picker.
    var connectedDeviceIDs: [UUID] {
        presenceSessions.values.compactMap { $0.isAuthenticated ? $0.deviceID : nil }
    }

    /// Broadcast `open_pane_request` to the target paired iPhone(s).
    /// If `deviceID` is nil, sends to every connected device.
    func pushOpenPane(paneID: String, to deviceID: UUID? = nil) {
        let targets = presenceSessions.values.filter { session in
            guard session.isAuthenticated else { return false }
            guard let filter = deviceID else { return true }
            return session.deviceID == filter
        }
        for session in targets {
            session.sendOpenPaneRequest(paneID: paneID)
        }
        presenceLogger.log("push_open_pane pane=\(paneID, privacy: .public) targets=\(targets.count, privacy: .public)")
    }

    /// Broadcast `panes_delta` to every authenticated presence session. Called
    /// by `PaneStatusTracker` whenever the pane set changes.
    func broadcastPanesDelta(_ delta: [String: Any]) {
        for session in presenceSessions.values where session.isAuthenticated {
            session.sendPanesDelta(delta)
        }
    }

    /// Broadcast a full mirror snapshot to every authenticated presence
    /// session. The snapshot includes the legacy flat pane list plus the
    /// current Mac window/workspace/pane hierarchy for the iOS mirror UI.
    func broadcastPanesSnapshot() {
        for session in presenceSessions.values where session.isAuthenticated {
            session.sendPanesSnapshot()
        }
    }

    /// Issues a fresh attach nonce bound to `paneID` + `deviceID`. PresenceSession
    /// calls this in response to `attach_pane`.
    func issueAttachNonce(paneID: String, deviceID: UUID) -> String {
        PaneAttachRegistry.shared.issue(paneID: paneID, deviceID: deviceID)
    }

    // MARK: - Listener setup

    private func makeListener(preferredPort: UInt16) throws -> NWListener {
        let wsOptions = NWProtocolWebSocket.Options(.version13)
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 1_048_576
        wsOptions.setClientRequestHandler(queue) { _, _ in
            .init(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // Try cached port first for client cache stability; fall back to random.
        if preferredPort >= 1024, let port = NWEndpoint.Port(rawValue: preferredPort) {
            if let listener = try? NWListener(using: parameters, on: port) {
                return listener
            }
            presenceLogger.log("preferred_port_unavailable port=\(preferredPort, privacy: .public) falling_back_random")
        }
        return try NWListener(using: parameters, on: .any)
    }

    private func handlePresenceListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = presenceListener?.port?.rawValue {
                presencePort = port
                UserDefaults.standard.set(Int(port), forKey: DefaultsKey.presencePort)
                presenceLogger.log("presence_listener_ready port=\(port, privacy: .public)")
            }
        case .failed(let error):
            presenceLogger.error("presence_listener_failed error=\(error.localizedDescription, privacy: .public)")
            stop()
        case .cancelled:
            presenceLogger.log("presence_listener_cancelled")
        default:
            break
        }
    }

    private func handleAttachListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = attachListener?.port?.rawValue {
                attachPort = port
                UserDefaults.standard.set(Int(port), forKey: DefaultsKey.attachPort)
                presenceLogger.log("attach_listener_ready port=\(port, privacy: .public)")
            }
        case .failed(let error):
            presenceLogger.error("attach_listener_failed error=\(error.localizedDescription, privacy: .public)")
            stop()
        case .cancelled:
            presenceLogger.log("attach_listener_cancelled")
        default:
            break
        }
    }

    // MARK: - Accept

    private func acceptPresence(_ connection: NWConnection) {
        let endpoint = String(describing: connection.endpoint)
        guard Self.shouldAcceptRemote(connection: connection) else {
            presenceLogger.log("presence_rejected_public_endpoint host=\(endpoint, privacy: .public)")
            connection.cancel()
            return
        }

        let id = UUID()
        let session = PresenceSession(
            id: id,
            connection: connection,
            onTerminate: { [weak self] sid in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.presenceSessions.removeValue(forKey: sid)
                    self.broadcastMembershipChange()
                }
            },
            onAuthenticated: { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.broadcastMembershipChange()
                }
            }
        )
        presenceSessions[id] = session
        session.start()
        presenceLogger.log("presence_accepted session=\(id.uuidString, privacy: .public) endpoint=\(endpoint, privacy: .public)")
    }

    private func acceptAttach(_ connection: NWConnection) {
        let endpoint = String(describing: connection.endpoint)
        guard Self.shouldAcceptRemote(connection: connection) else {
            presenceLogger.log("attach_rejected_public_endpoint host=\(endpoint, privacy: .public)")
            connection.cancel()
            return
        }

        let id = UUID()
        let session = PaneStreamSession(
            id: id,
            connection: connection,
            onTerminate: { [weak self] sid in
                Task { @MainActor [weak self] in
                    self?.attachSessions.removeValue(forKey: sid)
                    // Attach-session teardown flips the iphone device badge
                    // off in the sidebar — broadcast so observers refresh.
                    self?.broadcastMembershipChange()
                }
            }
        )
        attachSessions[id] = session
        session.start()
        // Equivalent signal on attach start: iphone badge turns on for the
        // pane the session eventually binds to (bind happens asynchronously
        // inside PaneStreamSession; another broadcast could fire from
        // there, but this early post at least shows "someone is attaching").
        broadcastMembershipChange()
        presenceLogger.log("attach_accepted session=\(id.uuidString, privacy: .public) endpoint=\(endpoint, privacy: .public)")
    }

    // MARK: - Attach query (used by sidebar row device badges)

    /// Returns every paired device currently streaming the given pane.
    /// Called per-row by `WorkspaceSidebarListView.buildRows`.
    func attachedDevices(forPane paneID: String) -> [UUID] {
        attachSessions.values.compactMap { session in
            session.boundPaneID == paneID ? session.boundDeviceID : nil
        }
    }

    // MARK: - LAN filter

    /// Copy of `LocalTerminalHandoffManager.isPrivateRemoteHost`. Kept here
    /// (deliberately duplicated, ~20 lines) to avoid exposing internals of
    /// that file. Will converge if/when we extract a shared NetworkRanges helper.
    private static func shouldAcceptRemote(connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return true }
        let raw = host.debugDescription
        let stripped = raw.split(separator: "%").first.map(String.init) ?? raw

        if let v4 = IPv4Address(stripped) {
            let bytes = v4.rawValue
            guard bytes.count == 4 else { return false }
            let b0 = bytes[0], b1 = bytes[1]
            if b0 == 10 { return true }
            if b0 == 127 { return true }
            if b0 == 192 && b1 == 168 { return true }
            if b0 == 172 && (16...31).contains(b1) { return true }
            if b0 == 100 && (64...127).contains(b1) { return true }
            if b0 == 169 && b1 == 254 { return true }
            return false
        }
        if let v6 = IPv6Address(stripped) {
            let bytes = v6.rawValue
            guard bytes.count == 16 else { return false }
            let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            if loopback { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                let mapped = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
                if let v4 = IPv4Address(mapped) {
                    let b0 = v4.rawValue[0], b1 = v4.rawValue[1]
                    if b0 == 10 { return true }
                    if b0 == 127 { return true }
                    if b0 == 192 && b1 == 168 { return true }
                    if b0 == 172 && (16...31).contains(b1) { return true }
                    if b0 == 100 && (64...127).contains(b1) { return true }
                }
                return false
            }
            let b0 = bytes[0], b1 = bytes[1]
            if b0 == 0xfe && (b1 & 0xc0) == 0x80 { return true }
            if (b0 & 0xfe) == 0xfc { return true }
            return false
        }
        return false
    }
}
