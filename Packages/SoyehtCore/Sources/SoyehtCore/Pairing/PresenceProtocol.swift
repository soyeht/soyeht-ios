import Foundation

/// Wire protocol for the persistent presence channel and pane attach stream
/// introduced in Fase 2. Layers on top of `PairingProtocol` (which handles the
/// initial pair/resume) — the HMAC primitives, deny reasons and challenge
/// message are reused.
///
/// Two WebSocket routes share the same app-level listener on the Mac:
///   - `ws://mac:port/presence?mac_id=…` carries JSON control messages (this file).
///   - `ws://mac:port/panes/<id>/attach?nonce=…` carries the PTY binary stream
///     plus the `input`/`resize` text frames already defined in `PairingMessage`.
public enum PresenceMessage {
    // iPhone → Mac
    public static let presenceHello      = "presence_hello"
    public static let challengeResponse  = PairingMessage.challengeResponse
    public static let listPanes          = "list_panes"
    public static let attachPane         = "attach_pane"
    public static let pingClient         = "ping"

    // Mac → iPhone
    public static let challenge          = PairingMessage.challenge
    public static let presenceReady      = "presence_ready"
    public static let panesSnapshot      = "panes_snapshot"
    public static let panesDelta         = "panes_delta"
    public static let paneStatus         = "pane_status"
    public static let attachGranted      = "attach_granted"
    public static let attachDenied       = "attach_denied"
    public static let openPaneRequest    = "open_pane_request"
    public static let presenceDenied     = "presence_denied"
    public static let pongServer         = "pong"
}

/// WebSocket URL path routing used by `PairingPresenceServer`.
public enum PresencePath {
    public static let presence = "/presence"
    /// Returns `"/panes/<id>/attach"` with the given pane id.
    public static func paneAttach(paneID: String) -> String {
        "/panes/\(paneID)/attach"
    }
    /// Tries to extract the pane id from a path matching the attach pattern.
    public static func paneIDFromAttachPath(_ path: String) -> String? {
        // "/panes/<id>/attach" — split on "/"; expect ["", "panes", "<id>", "attach"]
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[1] == "panes", parts[3] == "attach" else { return nil }
        let id = String(parts[2])
        guard !id.isEmpty else { return nil }
        return id
    }
}

/// Query param keys on the presence/attach URLs.
public enum PresenceQueryKey {
    public static let macID  = "mac_id"
    public static let nonce  = "nonce"
}

/// Pane status reported in `panes_snapshot` / `panes_delta` / `pane_status`.
/// Wire format is a string; Mac encodes and iPhone decodes.
public enum PaneWireStatus {
    public static let active = "active"   // output within the active window
    public static let idle   = "idle"     // no output >= idleThreshold but alive
    public static let dead   = "dead"     // process exited or WS closed (terminal state)
    public static let mirror = "mirror"   // remote tmux mirror, tracked via WS
}

/// Wire-level agent identifiers. Mirror of `AgentType.rawValue` on the Mac so
/// the iPhone can render consistent icons without sharing the enum.
public enum PaneWireAgent {
    public static let shell  = "shell"
    public static let claude = "claude"
    public static let codex  = "codex"
    public static let hermes = "hermes"
}

/// Compose HMAC message for the presence `challenge_response`. Byte layout is
/// deliberately distinct from `PairingHMACInput` — presence binds server+client
/// nonces only (no pane_nonce) and normalizes device ID case (lowercased) so
/// Mac/iPhone agree regardless of how the UUID was formatted on the wire.
public enum PresenceHMACInput {
    public static func parts(
        serverNonce: Data,
        clientNonce: Data,
        deviceID: UUID
    ) -> [Data] {
        [
            serverNonce,
            clientNonce,
            Data(deviceID.uuidString.lowercased().utf8),
        ]
    }
}
