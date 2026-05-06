import Foundation

/// Wire protocol shared between the Mac handoff listener and the iOS client.
///
/// The handshake is JSON-over-WebSocket (text frames). Binary frames carry
/// PTY I/O once authenticated. Payload shape is dictionary-based to stay
/// compatible with the existing `JSONSerialization` path in
/// `LocalTerminalHandoffManager`.
public enum PairingMessage {
    public static let pairRequest        = "pair_request"
    public static let pairAccept         = "pair_accept"
    public static let pairDenied         = "pair_denied"
    public static let resumeRequest      = "resume_request"
    public static let challenge          = "challenge"
    public static let challengeResponse  = "challenge_response"
    public static let localHandoffReady  = "local_handoff_ready"
    public static let input              = "input"
    public static let resize             = "resize"
}

/// Bounds applied to untrusted `resize` / `input` payloads on the Mac side
/// of the pairing protocol. The other end of the WebSocket is a paired
/// device — authenticated, but still external — so payload shapes must
/// reject obvious DoS / overflow attempts before being forwarded to the
/// terminal session.
public enum PairingPayloadLimits {
    /// Terminal column count. The hard cap is far above any real layout
    /// (typical terminals run 80–200 columns; ultra-wide displays cap
    /// around 1000). Anything beyond 4096 is almost certainly an attempt
    /// to drive a downstream allocator into pathological behavior.
    public static let columnRange: ClosedRange<Int> = 1...4096

    /// Terminal row count. Same rationale as `columnRange`.
    public static let rowRange: ClosedRange<Int> = 1...4096

    /// Maximum byte length of an `input` payload. Generous enough for a
    /// realistic clipboard paste from the paired device, tight enough to
    /// keep an attacker from allocating gigabytes of `Data` per frame.
    public static let inputMaxBytes = 1 * 1024 * 1024  // 1 MiB
}

public enum PairingDenyReason {
    public static let revoked             = "revoked"
    public static let unknownDevice       = "unknown_device"
    public static let consentDenied       = "consent_denied"
    public static let tokenInvalid        = "token_invalid"
    public static let tokenConsumed       = "token_consumed"
    public static let challengeFailed     = "challenge_failed"
    public static let panePreempted       = "pane_preempted"
}

/// Deep link query keys for the QR payload.
public enum PairingQueryKey {
    public static let localHandoff  = "local_handoff"
    public static let macID         = "mac_id"
    public static let macName       = "mac_name"
    public static let pairToken     = "pair_token"
    public static let paneNonce     = "pane_nonce"
    public static let presencePort  = "presence_port"
    public static let attachPort    = "attach_port"
    public static let wsURL         = "ws_url"
    public static let title         = "title"
    public static let expiresAt     = "exp"
    public static let scheme        = "theyos"
    public static let host          = "connect"
    public static let modeValue     = "mac_local"
}

/// Compose HMAC message for `challenge_response`.
/// Bytes are concatenated in a fixed order to avoid ambiguity.
public enum PairingHMACInput {
    public static func parts(
        challengeNonce: Data,
        paneNonce: Data,
        deviceID: String
    ) -> [Data] {
        [
            challengeNonce,
            paneNonce,
            Data(deviceID.utf8),
        ]
    }
}
