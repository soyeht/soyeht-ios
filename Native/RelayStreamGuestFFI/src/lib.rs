//! iOS guest core for Product A `relay_stream`.
//!
//! This crate is intentionally standalone for the first integration phase. It
//! reuses theyos `household-rs` protocol code directly and exposes
//! FFI-friendly data shapes around the guest-side dial sequence:
//!
//! 1. verify a canonical `RelayStreamOfferContract`;
//! 2. prepare exact `SessionAuthTokenUnsigned` bytes for Swift/Secure Enclave;
//! 3. accept a raw P-256 signature and build the data-tunnel auth envelope;
//! 4. drive rendezvous, Noise NK, health/open, and typed tunnel frames.
//!
//! It must stay relay_stream-only. Do not add alternate transport runtime or
//! private transit dependencies here.

#![deny(unsafe_code)]
#![allow(clippy::module_name_repetitions)]

use std::fmt;
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use household_rs::KeystoreError;
use household_rs::cbor;
use household_rs::claw_share::GuestCredential;
use household_rs::claw_share_data_tunnel::{
    AuthEnvelope, DataTunnelError, HEALTH_PROBE, MAX_FRAME_LEN, NetworkSettings, SessionAuthToken,
    TargetExit, TunnelAck, TunnelFrame, client_authenticate, client_health, client_open_stream,
    client_resize, decode_network_settings_body, recv_frame, send_frame,
};
use household_rs::claw_share_relay_stream_contract::{
    RelayStreamAudience, RelayStreamExpectedPath, RelayStreamOfferContract, RelayStreamResource,
};
use household_rs::claw_share_relay_stream_endpoint::parse_relay_endpoint;
use household_rs::claw_share_relay_stream_noise::{
    RelayStreamNoiseAsyncStream, RelayStreamNoiseError, RelayStreamNoiseFramed,
};
use household_rs::claw_share_rendezvous_hello::{RendezvousHello, RendezvousRole};
use household_rs::keys::{IdentityKey, P256PublicKey, P256Signature, verify_signature};
use rand::RngCore;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{Mutex as TokioMutex, mpsc, oneshot};

uniffi::setup_scaffolding!();

const SESSION_TOKEN_NONCE_LEN: usize = 16;
const SESSION_TOKEN_MAX_TTL_SECS: u64 = 300;
const DEFAULT_NETWORK_SETTINGS_TIMEOUT: Duration = Duration::from_secs(10);

/// Authentication material mode for the post-Noise data tunnel.
#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum RelayStreamAuthMode {
    /// Device/claim path: `AuthEnvelope.credential_cbor` is a signed
    /// `GuestCredential` bound to the consumed slot.
    DeviceCredential,
    /// Group/Public path: `AuthEnvelope.credential_cbor` carries the canonical
    /// offer payload and authorization is entirely offer/live-gate based.
    OfferPayload,
}

/// Input for preparing Secure-Enclave signing bytes.
#[derive(Clone, Eq, PartialEq, uniffi::Record)]
pub struct RelayStreamPrepareAuthInput {
    pub offer_cbor: Vec<u8>,
    pub credential_cbor: Option<Vec<u8>>,
    pub expected_owner_pub: Vec<u8>,
    pub expected_guest_pub: Vec<u8>,
    pub now_unix: u64,
    pub ttl_secs: u64,
    pub session_id: String,
    /// Test hook. Production should pass `None` and let Rust fill OS RNG bytes.
    pub nonce: Option<Vec<u8>>,
}

impl fmt::Debug for RelayStreamPrepareAuthInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RelayStreamPrepareAuthInput")
            .field("offer_cbor_len", &self.offer_cbor.len())
            .field(
                "credential_cbor_len",
                &self.credential_cbor.as_ref().map(Vec::len),
            )
            .field("expected_owner_pub_len", &self.expected_owner_pub.len())
            .field("expected_guest_pub_len", &self.expected_guest_pub.len())
            .field("now_unix", &self.now_unix)
            .field("ttl_secs", &self.ttl_secs)
            // A session id correlates a log line to a live session, so it is
            // redacted like the byte fields above rather than printed.
            .field("session_id", &"<redacted>")
            .field("nonce_len", &self.nonce.as_ref().map(Vec::len))
            .finish()
    }
}

/// Exact bytes Swift must sign with the guest device identity.
#[derive(Clone, Eq, PartialEq, uniffi::Record)]
pub struct RelayStreamAuthSigningRequest {
    pub auth_mode: RelayStreamAuthMode,
    pub signing_bytes: Vec<u8>,
    pub session_id: String,
    pub endpoint: String,
    pub target_id: String,
    pub expires_at: u64,
    /// Non-secret replay nonce. Redacted from Debug to keep logs boring.
    pub nonce: Vec<u8>,
    /// Credential CBOR for Device, offer payload CBOR for Group/Public.
    pub auth_material_cbor: Vec<u8>,
    pub guest_device_pub: Vec<u8>,
}

impl fmt::Debug for RelayStreamAuthSigningRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RelayStreamAuthSigningRequest")
            .field("auth_mode", &self.auth_mode)
            .field("signing_bytes_len", &self.signing_bytes.len())
            // `endpoint` is a real relay address and `target_id` names the
            // selected Claw; with `session_id` these are exactly the identifiers
            // a drained log must not carry. The neighbouring `nonce` was already
            // redacted "to keep logs boring" — these are strictly more sensitive.
            .field("session_id", &"<redacted>")
            .field("endpoint", &"<redacted>")
            .field("target_id", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("nonce_len", &self.nonce.len())
            .field("auth_material_cbor_len", &self.auth_material_cbor.len())
            .field("guest_device_pub_len", &self.guest_device_pub.len())
            .finish()
    }
}

/// Frame events surfaced to Swift after the tunnel is open.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelayStreamGuestFrame {
    Data(Vec<u8>),
    Window(u32),
    ExitCode(i32),
    ExitSignal(i32),
    ExitLost,
    Close,
    Error(String),
    Health(Vec<u8>),
    Open,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum RelayStreamGuestFrameKind {
    Data,
    Window,
    ExitCode,
    ExitSignal,
    ExitLost,
    Close,
    Error,
    Health,
    Open,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RelayStreamGuestFrameRecord {
    pub kind: RelayStreamGuestFrameKind,
    pub data: Vec<u8>,
    pub number: i64,
    pub text: String,
}

/// IPv4 assignment authenticated inside the post-Open Noise channel.
#[derive(Clone, Eq, PartialEq, uniffi::Record)]
pub struct RelayStreamGuestIpv4Metadata {
    pub addr: String,
    pub prefix_len: u8,
    pub peer: String,
}

/// Hand-written so the assignment cannot reach a log through a formatter: these
/// are the guest's real tunnel address and its claw-side peer, i.e. live VPN
/// topology. `prefix_len` stays visible because a route scope is diagnosable
/// without identifying anyone. A derived `Debug` would print both addresses.
impl fmt::Debug for RelayStreamGuestIpv4Metadata {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RelayStreamGuestIpv4Metadata")
            .field("addr", &"<redacted>")
            .field("prefix_len", &self.prefix_len)
            .field("peer", &"<redacted>")
            .finish()
    }
}

/// Network settings authenticated by the relay-stream responder.
///
/// The packet-tunnel extension only uses `mesh_ipv4` after the post-Open
/// `NetworkSettings` frame has been validated and cross-bound to the auth
/// `TunnelAck` session id and MTU. It never accepts these values from
/// host-provided start options.
#[derive(Clone, Eq, PartialEq, uniffi::Record)]
pub struct RelayStreamGuestSessionMetadata {
    pub mesh_ipv4: Option<RelayStreamGuestIpv4Metadata>,
    pub mesh_ipv6: Option<String>,
    pub mtu: u16,
    pub session_id: String,
}

/// Same rule as [`RelayStreamGuestIpv4Metadata`]. `mesh_ipv6` is an address and
/// `session_id` correlates a log to a live session, so both are redacted;
/// presence booleans keep the value diagnosable without identifying it.
impl fmt::Debug for RelayStreamGuestSessionMetadata {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RelayStreamGuestSessionMetadata")
            .field("mesh_ipv4", &self.mesh_ipv4)
            .field("mesh_ipv6_present", &self.mesh_ipv6.is_some())
            .field("mtu", &self.mtu)
            .field("session_id", &"<redacted>")
            .finish()
    }
}

impl From<RelayStreamGuestFrame> for RelayStreamGuestFrameRecord {
    fn from(frame: RelayStreamGuestFrame) -> Self {
        match frame {
            RelayStreamGuestFrame::Data(data) => Self {
                kind: RelayStreamGuestFrameKind::Data,
                data,
                number: 0,
                text: String::new(),
            },
            RelayStreamGuestFrame::Window(n) => Self {
                kind: RelayStreamGuestFrameKind::Window,
                data: Vec::new(),
                number: i64::from(n),
                text: String::new(),
            },
            RelayStreamGuestFrame::ExitCode(code) => Self {
                kind: RelayStreamGuestFrameKind::ExitCode,
                data: Vec::new(),
                number: i64::from(code),
                text: String::new(),
            },
            RelayStreamGuestFrame::ExitSignal(signal) => Self {
                kind: RelayStreamGuestFrameKind::ExitSignal,
                data: Vec::new(),
                number: i64::from(signal),
                text: String::new(),
            },
            RelayStreamGuestFrame::ExitLost => Self {
                kind: RelayStreamGuestFrameKind::ExitLost,
                data: Vec::new(),
                number: 0,
                text: String::new(),
            },
            RelayStreamGuestFrame::Close => Self {
                kind: RelayStreamGuestFrameKind::Close,
                data: Vec::new(),
                number: 0,
                text: String::new(),
            },
            RelayStreamGuestFrame::Error(text) => Self {
                kind: RelayStreamGuestFrameKind::Error,
                data: Vec::new(),
                number: 0,
                text,
            },
            RelayStreamGuestFrame::Health(data) => Self {
                kind: RelayStreamGuestFrameKind::Health,
                data,
                number: 0,
                text: String::new(),
            },
            RelayStreamGuestFrame::Open => Self {
                kind: RelayStreamGuestFrameKind::Open,
                data: Vec::new(),
                number: 0,
                text: String::new(),
            },
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RelayStreamGuestError {
    #[error("invalid relay_stream offer: {0}")]
    Offer(String),

    #[error("invalid guest credential: {0}")]
    Credential(String),

    #[error("relay_stream auth mode mismatch: {0}")]
    AuthMode(String),

    #[error("public key malformed")]
    PublicKeyMalformed,

    #[error("signature malformed")]
    SignatureMalformed,

    #[error("signature does not verify for prepared auth bytes")]
    SignatureRejected,

    #[error("session id is empty")]
    SessionIdEmpty,

    #[error("session auth ttl must be in 1...300 seconds")]
    InvalidTtl,

    #[error("session auth nonce must be 16 bytes")]
    InvalidNonce,

    #[error("relay_stream endpoint rejected: {0}")]
    Endpoint(String),

    #[error("auth rejected: {0}")]
    AuthRejected(String),

    #[error("health echo mismatch")]
    HealthMismatch,

    #[error("io error: {0}")]
    Io(String),

    #[error("cbor error: {0}")]
    Cbor(String),

    #[error("relay_stream Noise error: {0}")]
    Noise(String),

    #[error("data tunnel error: {0}")]
    DataTunnel(String),
}

impl From<RelayStreamNoiseError> for RelayStreamGuestError {
    fn from(error: RelayStreamNoiseError) -> Self {
        Self::Noise(error.to_string())
    }
}

impl From<DataTunnelError> for RelayStreamGuestError {
    fn from(error: DataTunnelError) -> Self {
        Self::DataTunnel(error.to_string())
    }
}

#[derive(uniffi::Object)]
pub struct RelayStreamGuestSession {
    command_tx: mpsc::Sender<RelayStreamGuestCommand>,
    frame_rx:
        TokioMutex<mpsc::Receiver<Result<RelayStreamGuestFrameRecord, RelayStreamGuestError>>>,
    metadata: RelayStreamGuestSessionMetadata,
    // Guards `OpenPersistent` framing (see [`OPEN_PERSISTENT_FRAME`]): exactly
    // one target may be open at a time, and the server tears down the WHOLE
    // connection if a new target-open arrives before the current one closed.
    // `true` right after `relay_stream_connect`/`relay_stream_connect_persistent`
    // (the initial Open/OpenPersistent already ack'd); flipped to `false` the
    // moment ANY `read_frame()` observes a `Close` — not only inside
    // `send_close` itself — because the server can send `Close`
    // unsolicited (the target ending on its own) just as easily as it can
    // echo one back. `open_next_target` flips it back to `true` on success.
    target_open: TokioMutex<bool>,
    // Serializes the ENTIRE lifecycle operation -- check, command
    // write/result, and this call's own ack drain -- between `send_close`
    // and `open_next_target`. Held for the whole duration of either call
    // (not just around the `target_open` check), so a concurrent second
    // `send_close` genuinely WAITS for the first to finish draining (then
    // observes `target_open == false` and returns idempotently, no second
    // `Close` command ever written), and `open_next_target` cannot write
    // `OpenNextTarget` while a `send_close` on the same session is still
    // mid-flight -- the two commands can never interleave on `command_tx`.
    // `target_open` stays a separate, lighter mutex on purpose: `read_frame`
    // updates it from contexts that never touch this lock (an unsolicited
    // server `Close` can arrive while neither of these two calls is
    // running), and nesting would risk exactly the deadlock this design
    // avoids by keeping the two concerns on two locks.
    target_operation: TokioMutex<()>,
    // Distinguishes `relay_stream_connect` from `relay_stream_connect_persistent`.
    // ONLY a persistent session's server ever echoes a `Close` ack or treats
    // a redundant one as an idempotent no-op (theyos
    // `2ff5599aa76bb1fdbb390905d3d41fbfc6c33f8c` — "make persistent target
    // close retry idempotent"); a legacy session's server shuts the whole
    // connection down on a client-initiated `Close` with NO echo at all, so
    // `send_close` must not go looking for one there — see its doc.
    persistent: bool,
}

enum RelayStreamGuestCommand {
    Data(Vec<u8>, oneshot::Sender<Result<(), RelayStreamGuestError>>),
    Resize(u16, u16, oneshot::Sender<Result<(), RelayStreamGuestError>>),
    Close(oneshot::Sender<Result<(), RelayStreamGuestError>>),
    OpenNextTarget(oneshot::Sender<Result<(), RelayStreamGuestError>>),
}

#[uniffi::export]
pub fn relay_stream_rendezvous_hello_bytes(
    offer_cbor: Vec<u8>,
) -> Result<Vec<u8>, RelayStreamGuestError> {
    rendezvous_hello_bytes(&offer_cbor)
}

#[uniffi::export]
pub fn relay_stream_prepare_auth_signing_request(
    input: RelayStreamPrepareAuthInput,
) -> Result<RelayStreamAuthSigningRequest, RelayStreamGuestError> {
    prepare_auth_signing_request(input)
}

#[uniffi::export]
pub fn relay_stream_encode_auth_envelope(
    request: RelayStreamAuthSigningRequest,
    signature: Vec<u8>,
) -> Result<Vec<u8>, RelayStreamGuestError> {
    encode_auth_envelope(&request, &signature)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn relay_stream_connect(
    offer_cbor: Vec<u8>,
    expected_owner_pub: Vec<u8>,
    expected_guest_pub: Vec<u8>,
    request: RelayStreamAuthSigningRequest,
    signature: Vec<u8>,
    now_unix: u64,
    connect_timeout_ms: u64,
) -> Result<Arc<RelayStreamGuestSession>, RelayStreamGuestError> {
    let offer = decode_canonical_offer(&offer_cbor)?;
    let requires_network_metadata = offer.payload.resource == RelayStreamResource::IpTunnel;
    let connect_timeout = Duration::from_millis(connect_timeout_ms);
    let stream = connect_relay_stream_tcp(
        &offer_cbor,
        &expected_owner_pub,
        &expected_guest_pub,
        now_unix,
        connect_timeout,
    )
    .await?;
    let (stream, metadata) = authenticate_health_open_with_metadata(
        stream,
        &request,
        &signature,
        requires_network_metadata,
        connect_timeout,
    )
    .await?;
    let (read_half, write_half) = tokio::io::split(stream);
    let (command_tx, command_rx) = mpsc::channel(32);
    let (frame_tx, frame_rx) = mpsc::channel(32);
    tokio::spawn(drive_guest_writer(write_half, command_rx, false));
    tokio::spawn(drive_guest_reader(read_half, frame_tx));
    Ok(Arc::new(RelayStreamGuestSession {
        command_tx,
        frame_rx: TokioMutex::new(frame_rx),
        metadata,
        target_open: TokioMutex::new(true),
        target_operation: TokioMutex::new(()),
        persistent: false,
    }))
}

/// Connect and negotiate `OpenPersistent` (0x18) for the first target instead
/// of the legacy single-shot `Open` (0x10).
///
/// **Provenance note.** `OpenPersistent` IS part of the vendored wire enum. The
/// enum lives in the `tunnel-wire-rs` crate and is re-exported unchanged
/// (`household_rs::claw_share_data_tunnel` does `pub use
/// tunnel_wire_rs::tunnel_wire::{TunnelFrame, WireError}`), where
/// `FRAME_OPEN_PERSISTENT = 0x18` encodes as a bare opcode with no payload.
/// `.vendor` snapshot at rev `43a517f0d8b527130ca734e4e1727190e96b04f0`.
///
/// An earlier revision of this note recorded that 0x18 was absent from the then
/// pinned enum, that the opcode, its bare framing and the "ack is always the
/// legacy `TunnelFrame::Open`" contract had been hand-reproduced, and asked for
/// a re-diff against the landed form before trusting it again. **That re-diff
/// was done against this pin, and all three hold**: the opcode is 0x18, the
/// frame is bare, and the server's ack is the legacy `TunnelFrame::Open`,
/// emitted as the explicit stream-ready ack after negotiation succeeds.
///
/// Three server behaviours are NOT described by that reproduction. The server
/// rejects with `TunnelFrame::Error` carrying `persistent-target-not-authorized`
/// when the credential does not allow persistent targets, and
/// `session-open-budget-exhausted` once a session exceeds
/// `PERSISTENT_MAX_TARGET_OPENS` (128); and a legacy `Open` sent after
/// persistent mode is negotiated is refused outright. This client routes any
/// typed `TunnelFrame::Error` through [`client_open_persistent_stream`], so all
/// three surface rather than hang — but they surface as `AuthRejected`, which
/// reads oddly for a budget that is not an authorization failure. Worth a typed
/// variant if callers ever need to tell them apart.
///
/// Authorization for `OpenPersistent` is entirely a
/// property of the ONE initial signed `request`/`signature` (server derives
/// `allows_persistent_targets` from the offer's resource == `ClawSite`, once,
/// at connect time) — there is deliberately no per-target request/signature
/// here; see [`RelayStreamGuestSession::open_next_target`].
#[uniffi::export(async_runtime = "tokio")]
pub async fn relay_stream_connect_persistent(
    offer_cbor: Vec<u8>,
    expected_owner_pub: Vec<u8>,
    expected_guest_pub: Vec<u8>,
    request: RelayStreamAuthSigningRequest,
    signature: Vec<u8>,
    now_unix: u64,
    connect_timeout_ms: u64,
) -> Result<Arc<RelayStreamGuestSession>, RelayStreamGuestError> {
    let offer = decode_canonical_offer(&offer_cbor)?;
    let requires_network_metadata = offer.payload.resource == RelayStreamResource::IpTunnel;
    let connect_timeout = Duration::from_millis(connect_timeout_ms);
    let stream = connect_relay_stream_tcp(
        &offer_cbor,
        &expected_owner_pub,
        &expected_guest_pub,
        now_unix,
        connect_timeout,
    )
    .await?;
    let (stream, metadata) = authenticate_health_open_persistent_with_metadata(
        stream,
        &request,
        &signature,
        requires_network_metadata,
        connect_timeout,
    )
    .await?;
    let (read_half, write_half) = tokio::io::split(stream);
    let (command_tx, command_rx) = mpsc::channel(32);
    let (frame_tx, frame_rx) = mpsc::channel(32);
    tokio::spawn(drive_guest_writer(write_half, command_rx, true));
    tokio::spawn(drive_guest_reader(read_half, frame_tx));
    Ok(Arc::new(RelayStreamGuestSession {
        command_tx,
        frame_rx: TokioMutex::new(frame_rx),
        metadata,
        target_open: TokioMutex::new(true),
        target_operation: TokioMutex::new(()),
        persistent: true,
    }))
}

#[uniffi::export(async_runtime = "tokio")]
impl RelayStreamGuestSession {
    pub async fn metadata(&self) -> RelayStreamGuestSessionMetadata {
        self.metadata.clone()
    }

    /// Close the current target (see [`RelayStreamGuestSession::send_close`]),
    /// then open the next one over the SAME authenticated Noise connection via
    /// `OpenPersistent` (0x18) — no new signing, no new `RelayStreamAuthSigningRequest`.
    /// Errors closed: calling this while a target is already open is
    /// rejected locally without writing anything, because the server treats
    /// an out-of-turn `OpenPersistent` as a framing violation and drops the
    /// whole connection.
    ///
    /// **Atomic.** The write AND its ack are both handled inside this call,
    /// through the SAME `read_frame` path `read_frame()` itself uses —
    /// deliberately not a second reader on `frame_rx` (there is exactly one
    /// consumer slot, guarded by `frame_rx`'s mutex). Callers never observe
    /// the ack frame this produces: a bare `TunnelFrame::Open` here means
    /// success and is fully consumed before returning `Ok`; a `.error` kind
    /// is a rejection (budget exhausted or not authorized), consumed and
    /// turned into `Err` — the whole session should be treated as dead
    /// either way, not retried.
    pub async fn open_next_target(&self) -> Result<(), RelayStreamGuestError> {
        let _operation_guard = self.target_operation.lock().await;
        {
            let mut open = self.target_open.lock().await;
            if *open {
                return Err(RelayStreamGuestError::DataTunnel(
                    "open_next_target called while a target is still open".to_string(),
                ));
            }
            *open = true;
        }
        let (tx, rx) = oneshot::channel();
        if self
            .command_tx
            .send(RelayStreamGuestCommand::OpenNextTarget(tx))
            .await
            .is_err()
        {
            *self.target_open.lock().await = false;
            return Err(RelayStreamGuestError::Io(
                "relay stream session closed".to_string(),
            ));
        }
        if let Err(error) = rx
            .await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?
        {
            *self.target_open.lock().await = false;
            return Err(error);
        }
        match self.read_frame().await {
            Ok(record) if record.kind == RelayStreamGuestFrameKind::Open => Ok(()),
            Ok(record) if record.kind == RelayStreamGuestFrameKind::Error => {
                *self.target_open.lock().await = false;
                Err(RelayStreamGuestError::AuthRejected(record.text))
            }
            Ok(_) => {
                *self.target_open.lock().await = false;
                Err(RelayStreamGuestError::Io(
                    "expected open-next-target ack".to_string(),
                ))
            }
            Err(error) => {
                *self.target_open.lock().await = false;
                Err(error)
            }
        }
    }

    pub async fn send_data(&self, data: Vec<u8>) -> Result<(), RelayStreamGuestError> {
        let (tx, rx) = oneshot::channel();
        self.command_tx
            .send(RelayStreamGuestCommand::Data(data, tx))
            .await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?;
        rx.await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?
    }

    pub async fn send_resize(&self, cols: u16, rows: u16) -> Result<(), RelayStreamGuestError> {
        let (tx, rx) = oneshot::channel();
        self.command_tx
            .send(RelayStreamGuestCommand::Resize(cols, rows, tx))
            .await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?;
        rx.await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?
    }

    /// Close the current target. Safe to call once its response has been
    /// fully consumed even if the target's own backend would otherwise keep
    /// its connection alive (e.g. HTTP keep-alive): the bridge — not the
    /// backend — decides when a target stream ends, so a persistent session
    /// never lets keep-alive smuggle state across `open_next_target` calls.
    ///
    /// **Idempotent on a persistent session.** If `target_open` is already
    /// `false` — some earlier `read_frame()` already observed the server's
    /// `Close` for this target, e.g. the backend ended on its own before the
    /// caller got around to closing — this returns `Ok(())` immediately
    /// without writing anything. That is load-bearing, not an optimization:
    /// theyos `2ff5599aa76bb1fdbb390905d3d41fbfc6c33f8c` makes a REDUNDANT
    /// `Close` in that state a server-side no-op with **no second ack**, so
    /// writing one and then draining for an ack would hang forever.
    ///
    /// **Otherwise atomic**, same reasoning as `open_next_target`: drains the
    /// server's lifecycle ack (a bare `TunnelFrame::Close`, possibly preceded
    /// by an `Exit` if the target's own process ended around the same time)
    /// through the SAME `read_frame` path before returning, so it never
    /// reaches a caller's `read_frame()` — a stray leftover `Close` there
    /// would otherwise be indistinguishable from the NEXT exchange's target
    /// ending before its response arrived (this is exactly the bug the
    /// idempotency above also has to coexist with, not paper over: draining
    /// here AND flagging in `read_frame` are two sides of the same fix). Any
    /// OTHER frame here — most of all `Data` — means the caller closed
    /// before actually consuming everything the target sent for this
    /// exchange: fails closed rather than silently dropping (or worse,
    /// leaking into the next exchange's read) unaccounted response bytes.
    ///
    /// A LEGACY (non-persistent) session's server never echoes a `Close` at
    /// all — a client-initiated `Close` just ends the whole connection
    /// (`writer.shutdown` + `return Ok(())`, no frame back) — so draining
    /// here would wait for something that is never coming. `persistent`
    /// gates the whole drain/idempotency mechanism off for that case,
    /// preserving the exact original write-and-return behavior.
    pub async fn send_close(&self) -> Result<(), RelayStreamGuestError> {
        let _operation_guard = if self.persistent {
            Some(self.target_operation.lock().await)
        } else {
            None
        };
        if self.persistent && !*self.target_open.lock().await {
            return Ok(());
        }
        let (tx, rx) = oneshot::channel();
        self.command_tx
            .send(RelayStreamGuestCommand::Close(tx))
            .await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?;
        let result = rx
            .await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?;
        if !self.persistent {
            return result;
        }
        result?;
        loop {
            match self.read_frame().await {
                Ok(record)
                    if matches!(
                        record.kind,
                        RelayStreamGuestFrameKind::ExitCode
                            | RelayStreamGuestFrameKind::ExitSignal
                            | RelayStreamGuestFrameKind::ExitLost
                    ) =>
                {
                    continue;
                }
                // `read_frame` already set `target_open = false` for this
                // Close before returning it here — nothing left to do.
                Ok(record) if record.kind == RelayStreamGuestFrameKind::Close => return Ok(()),
                Ok(_) => {
                    *self.target_open.lock().await = false;
                    return Err(RelayStreamGuestError::Io(
                        "unexpected frame while closing target".to_string(),
                    ));
                }
                Err(error) => {
                    *self.target_open.lock().await = false;
                    return Err(error);
                }
            }
        }
    }

    /// Every caller of this session reads frames through here — including
    /// `send_close`'s own ack drain, deliberately, rather than a second
    /// reader on `frame_rx` (there is exactly one consumer slot). A `Close`
    /// passing through, from ANY caller, means this target has ended: mark
    /// `target_open = false` right here so a subsequent `send_close` — from
    /// the bridge's own error path, when a spontaneous `Close` arrived via
    /// THIS call rather than `send_close`'s drain — knows there is no ack
    /// left to wait for.
    pub async fn read_frame(&self) -> Result<RelayStreamGuestFrameRecord, RelayStreamGuestError> {
        let record = self.read_frame_raw().await?;
        if record.kind == RelayStreamGuestFrameKind::Close {
            *self.target_open.lock().await = false;
        }
        Ok(record)
    }
}

// Deliberately NOT under `#[uniffi::export]`: uniffi's export macro exposes
// every method in the impl block it annotates regardless of Rust-level
// `pub`, so a plain (non-`pub`) method placed inside the exported block
// above still leaked into the generated Swift protocol/class/headers as
// `readFrameRaw()`. Moving it to its own, unannotated impl block is what
// actually keeps it internal to this crate -- omitting `pub` alone does not.
impl RelayStreamGuestSession {
    async fn read_frame_raw(&self) -> Result<RelayStreamGuestFrameRecord, RelayStreamGuestError> {
        let mut frame_rx = self.frame_rx.lock().await;
        frame_rx
            .recv()
            .await
            .ok_or_else(|| RelayStreamGuestError::Io("relay stream session closed".to_string()))?
    }
}

async fn drive_guest_writer<W>(
    mut stream: W,
    mut command_rx: mpsc::Receiver<RelayStreamGuestCommand>,
    persistent: bool,
) where
    W: AsyncWrite + Unpin,
{
    // Tracks whether the current target is already closed, so the drop-time
    // safety net below never sends a SECOND `Close` after an explicit one.
    // Sending `Close` while the server is in its pre-stream (no target open)
    // state is a framing violation there ("expected health or open before
    // stream") that tears down the whole connection — harmless once this
    // session is already being torn down too, but worth avoiding on
    // principle since it no longer reflects reality once other sessions can
    // share this same protocol shape.
    let mut target_closed = false;
    while let Some(command) = command_rx.recv().await {
        let should_stop = match command {
            RelayStreamGuestCommand::Data(data, reply) => {
                let result = send_data(&mut stream, &data).await;
                let should_stop = result.is_err();
                let _ = reply.send(result);
                should_stop
            }
            RelayStreamGuestCommand::Resize(cols, rows, reply) => {
                let result = send_resize(&mut stream, cols, rows).await;
                let should_stop = result.is_err();
                let _ = reply.send(result);
                should_stop
            }
            RelayStreamGuestCommand::Close(reply) => {
                // Terminal for a LEGACY session: its server never echoes a
                // `Close` ack and just ends the whole connection on receipt
                // (see `RelayStreamGuestSession::send_close`'s doc), so this
                // writer task has nothing left to do either — returning
                // immediately restores the pre-persistent-session behavior
                // instead of lingering, alive, until the `Arc` drops.
                //
                // NOT terminal for a PERSISTENT session: it sends `Close` to
                // end just the current target, then reuses this same writer
                // task for `open_next_target`.
                let result = send_close(&mut stream).await;
                let should_stop = result.is_err() || !persistent;
                if result.is_ok() {
                    target_closed = true;
                }
                let _ = reply.send(result);
                should_stop
            }
            RelayStreamGuestCommand::OpenNextTarget(reply) => {
                let result = write_open_persistent_frame(&mut stream).await;
                let should_stop = result.is_err();
                if result.is_ok() {
                    target_closed = false;
                }
                let _ = reply.send(result);
                should_stop
            }
        };
        if should_stop {
            return;
        }
    }
    if !target_closed {
        let _ = send_close(&mut stream).await;
    }
}

async fn drive_guest_reader<R>(
    mut stream: R,
    frame_tx: mpsc::Sender<Result<RelayStreamGuestFrameRecord, RelayStreamGuestError>>,
) where
    R: AsyncRead + Unpin,
{
    loop {
        match recv_guest_frame(&mut stream).await {
            Ok(frame) => {
                if frame_tx.send(Ok(frame.into())).await.is_err() {
                    return;
                }
            }
            Err(error) => {
                let _ = frame_tx.send(Err(error)).await;
                return;
            }
        }
    }
}

/// Return the relay-visible rendezvous hello bytes for a verified offer.
pub fn rendezvous_hello_bytes(offer_cbor: &[u8]) -> Result<Vec<u8>, RelayStreamGuestError> {
    let offer = decode_canonical_offer(offer_cbor)?;
    Ok(RendezvousHello::new(
        RendezvousRole::Guest,
        offer.payload.rendezvous_token.clone(),
    )
    .encode())
}

/// Prepare exact token bytes for Swift/Secure Enclave signing.
pub fn prepare_auth_signing_request(
    input: RelayStreamPrepareAuthInput,
) -> Result<RelayStreamAuthSigningRequest, RelayStreamGuestError> {
    if input.session_id.is_empty() {
        return Err(RelayStreamGuestError::SessionIdEmpty);
    }
    if input.ttl_secs == 0 || input.ttl_secs > SESSION_TOKEN_MAX_TTL_SECS {
        return Err(RelayStreamGuestError::InvalidTtl);
    }

    let owner = parse_public_key(&input.expected_owner_pub)?;
    let guest = parse_public_key(&input.expected_guest_pub)?;
    let offer = decode_canonical_offer(&input.offer_cbor)?;
    verify_offer_for_relay_stream(&offer, &owner, &guest, input.now_unix)?;
    let (_host, _port) = parse_relay_endpoint(&offer.payload.relay_endpoint)
        .map_err(|error| RelayStreamGuestError::Endpoint(error.to_string()))?;

    let (auth_mode, auth_material_cbor) = match input.credential_cbor {
        Some(credential_cbor) => {
            if offer.payload.audience() != RelayStreamAudience::Device {
                return Err(RelayStreamGuestError::AuthMode(
                    "credential auth requires a Device offer".to_string(),
                ));
            }
            verify_credential_binding(&credential_cbor, &offer, &owner, &guest)?;
            (RelayStreamAuthMode::DeviceCredential, credential_cbor)
        }
        None => {
            if offer.payload.audience() == RelayStreamAudience::Device {
                return Err(RelayStreamGuestError::AuthMode(
                    "Device offer requires credential auth material".to_string(),
                ));
            }
            let bytes = offer
                .payload
                .to_canonical_bytes()
                .map_err(|error| RelayStreamGuestError::Cbor(error.to_string()))?;
            (RelayStreamAuthMode::OfferPayload, bytes)
        }
    };

    let nonce = match input.nonce {
        Some(nonce) => nonce,
        None => {
            let mut nonce = vec![0u8; SESSION_TOKEN_NONCE_LEN];
            rand::rngs::OsRng.fill_bytes(&mut nonce);
            nonce
        }
    };
    if nonce.len() != SESSION_TOKEN_NONCE_LEN {
        return Err(RelayStreamGuestError::InvalidNonce);
    }

    let expires_at = input.now_unix.saturating_add(input.ttl_secs);
    let signing_bytes = token_signing_bytes(
        &input.session_id,
        &auth_material_cbor,
        &offer.payload.relay_endpoint,
        &offer.payload.claw_id,
        &nonce,
        expires_at,
        guest.clone(),
    )?;

    Ok(RelayStreamAuthSigningRequest {
        auth_mode,
        signing_bytes,
        session_id: input.session_id,
        endpoint: offer.payload.relay_endpoint,
        target_id: offer.payload.claw_id,
        expires_at,
        nonce,
        auth_material_cbor,
        guest_device_pub: guest.as_bytes().to_vec(),
    })
}

/// Build the canonical auth envelope bytes from a Swift-produced raw signature.
pub fn encode_auth_envelope(
    request: &RelayStreamAuthSigningRequest,
    signature: &[u8],
) -> Result<Vec<u8>, RelayStreamGuestError> {
    let token = signed_session_auth_token(request, signature)?;
    let envelope = AuthEnvelope {
        credential_cbor: request.auth_material_cbor.clone(),
        token,
    };
    cbor::to_canonical_vec(&envelope)
        .map_err(|error| RelayStreamGuestError::Cbor(error.to_string()))
}

/// Drive the theyos Noise initiator over an already-connected byte stream.
pub async fn initiate_noise_on_stream<S>(
    stream: S,
    offer_cbor: &[u8],
    expected_owner_pub: &[u8],
    expected_guest_pub: &[u8],
    now_unix: u64,
) -> Result<RelayStreamNoiseAsyncStream<S>, RelayStreamGuestError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let owner = parse_public_key(expected_owner_pub)?;
    let guest = parse_public_key(expected_guest_pub)?;
    let offer = decode_canonical_offer(offer_cbor)?;
    verify_offer_for_relay_stream(&offer, &owner, &guest, now_unix)?;
    let framed =
        RelayStreamNoiseFramed::initiator_handshake(stream, &offer, &owner, &guest, now_unix)
            .await?;
    Ok(framed.into_async_stream())
}

/// Dial the relay endpoint, send the rendezvous hello, and complete Noise NK.
pub async fn connect_relay_stream_tcp(
    offer_cbor: &[u8],
    expected_owner_pub: &[u8],
    expected_guest_pub: &[u8],
    now_unix: u64,
    connect_timeout: Duration,
) -> Result<RelayStreamNoiseAsyncStream<TcpStream>, RelayStreamGuestError> {
    let owner = parse_public_key(expected_owner_pub)?;
    let guest = parse_public_key(expected_guest_pub)?;
    let offer = decode_canonical_offer(offer_cbor)?;
    verify_offer_for_relay_stream(&offer, &owner, &guest, now_unix)?;
    let (host, port) = parse_relay_endpoint(&offer.payload.relay_endpoint)
        .map_err(|error| RelayStreamGuestError::Endpoint(error.to_string()))?;

    let mut stream =
        tokio::time::timeout(connect_timeout, TcpStream::connect((host.as_str(), port)))
            .await
            .map_err(|_| RelayStreamGuestError::Io("tcp connect timed out".to_string()))?
            .map_err(|error| RelayStreamGuestError::Io(error.to_string()))?;

    let hello = RendezvousHello::new(
        RendezvousRole::Guest,
        offer.payload.rendezvous_token.clone(),
    );
    stream
        .write_all(&hello.encode())
        .await
        .map_err(|error| RelayStreamGuestError::Io(error.to_string()))?;
    stream
        .flush()
        .await
        .map_err(|error| RelayStreamGuestError::Io(error.to_string()))?;

    let framed =
        RelayStreamNoiseFramed::initiator_handshake(stream, &offer, &owner, &guest, now_unix)
            .await?;
    Ok(framed.into_async_stream())
}

/// Authenticate, health-check, and open the relay_stream data tunnel.
pub async fn authenticate_health_open<S>(
    stream: S,
    request: &RelayStreamAuthSigningRequest,
    signature: &[u8],
) -> Result<S, RelayStreamGuestError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (stream, _) = authenticate_health_open_with_metadata(
        stream,
        request,
        signature,
        false,
        DEFAULT_NETWORK_SETTINGS_TIMEOUT,
    )
    .await?;
    Ok(stream)
}

/// Authenticate, health-check, and open the relay stream.
///
/// IpTunnel consumes exactly one post-Open `NetworkSettings` frame before
/// returning the session. Other resources preserve the existing auth
/// `TunnelAck` → Health → Open sequence unchanged.
pub async fn authenticate_health_open_with_metadata<S>(
    mut stream: S,
    request: &RelayStreamAuthSigningRequest,
    signature: &[u8],
    requires_network_metadata: bool,
    network_settings_timeout: Duration,
) -> Result<(S, RelayStreamGuestSessionMetadata), RelayStreamGuestError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (mesh_ipv6, auth_mtu, auth_session_id) =
        authenticate_and_health_check(&mut stream, request, signature).await?;
    client_open_stream(&mut stream).await?;
    let metadata = finish_open_metadata(
        &mut stream,
        requires_network_metadata,
        mesh_ipv6,
        auth_mtu,
        &auth_session_id,
        network_settings_timeout,
    )
    .await?;
    Ok((stream, metadata))
}

/// Authenticate, health-check, and open the FIRST target of a persistent
/// session via `OpenPersistent` (0x18) instead of legacy `Open` (0x10). See
/// [`relay_stream_connect_persistent`] for the wire-contract provenance note
/// — everything up to and including the `TunnelAck`/health exchange is
/// byte-identical to the legacy path; only the open frame differs.
pub async fn authenticate_health_open_persistent_with_metadata<S>(
    mut stream: S,
    request: &RelayStreamAuthSigningRequest,
    signature: &[u8],
    requires_network_metadata: bool,
    network_settings_timeout: Duration,
) -> Result<(S, RelayStreamGuestSessionMetadata), RelayStreamGuestError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (mesh_ipv6, auth_mtu, auth_session_id) =
        authenticate_and_health_check(&mut stream, request, signature).await?;
    client_open_persistent_stream(&mut stream).await?;
    let metadata = finish_open_metadata(
        &mut stream,
        requires_network_metadata,
        mesh_ipv6,
        auth_mtu,
        &auth_session_id,
        network_settings_timeout,
    )
    .await?;
    Ok((stream, metadata))
}

/// Shared prefix of both open paths: send the signed auth token, read the
/// `TunnelAck`, then the health round-trip. Pure extraction from the
/// pre-existing legacy sequence — behavior is unchanged for
/// [`authenticate_health_open_with_metadata`], which is exactly the same
/// calls in the exactly same order as before this function existed.
async fn authenticate_and_health_check<S>(
    stream: &mut S,
    request: &RelayStreamAuthSigningRequest,
    signature: &[u8],
) -> Result<(String, u16, String), RelayStreamGuestError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let token = signed_session_auth_token(request, signature)?;
    let (mesh_ipv6, auth_mtu, auth_session_id) =
        match client_authenticate(stream, &request.auth_material_cbor, token).await? {
            TunnelAck::Ok {
                mesh_ipv6,
                mtu,
                session_id,
            } => (mesh_ipv6, mtu, session_id),
            TunnelAck::Rejected { reason } => {
                return Err(RelayStreamGuestError::AuthRejected(reason));
            }
        };
    let echo = client_health(stream, HEALTH_PROBE).await?;
    if echo != HEALTH_PROBE {
        return Err(RelayStreamGuestError::HealthMismatch);
    }
    Ok((mesh_ipv6, auth_mtu, auth_session_id))
}

/// Shared suffix of both open paths, run immediately after the open frame's
/// ack has already been consumed by the caller (`client_open_stream` /
/// `client_open_persistent_stream`). Pure extraction, same as
/// [`authenticate_and_health_check`].
async fn finish_open_metadata<S>(
    stream: &mut S,
    requires_network_metadata: bool,
    mesh_ipv6: String,
    auth_mtu: u16,
    auth_session_id: &str,
    network_settings_timeout: Duration,
) -> Result<RelayStreamGuestSessionMetadata, RelayStreamGuestError>
where
    S: AsyncRead + Unpin,
{
    if requires_network_metadata {
        receive_ip_tunnel_network_settings(stream, auth_mtu, auth_session_id, network_settings_timeout)
            .await
    } else {
        Ok(RelayStreamGuestSessionMetadata {
            mesh_ipv4: None,
            mesh_ipv6: Some(mesh_ipv6),
            mtu: auth_mtu,
            session_id: auth_session_id.to_string(),
        })
    }
}

/// `OpenPersistent` (0x18): open one target stream inside an already
/// Noise-authenticated connection, without ending it when that target
/// closes. It IS part of the vendored `TunnelFrame` enum at the pinned rev,
/// which encodes and decodes it; this constant spells the opcode out for the
/// local raw writer below and for the tests that assert exact bytes. Framed
/// with a bare opcode byte and no payload, like `TunnelFrame::Open`/`Close`.
const OPEN_PERSISTENT_FRAME: u8 = 0x18;

/// Byte-identical envelope to `household_rs::claw_share_data_tunnel`'s
/// private `write_frame`: a `u32` big-endian length prefix followed by the
/// payload, capped at [`MAX_FRAME_LEN`].
///
/// It mirrors that private envelope and stands as an equivalent local path,
/// pinned as equivalent by the tests below. Collapsing onto the vendored
/// public API is a separate change — see [`client_open_persistent_stream`].
async fn write_raw_frame<W>(w: &mut W, payload: &[u8]) -> Result<(), RelayStreamGuestError>
where
    W: AsyncWrite + Unpin,
{
    if payload.len() > MAX_FRAME_LEN {
        return Err(RelayStreamGuestError::Io(format!(
            "frame too large: {} bytes",
            payload.len()
        )));
    }
    let len = u32::try_from(payload.len())
        .map_err(|_| RelayStreamGuestError::Io(format!("frame too large: {} bytes", payload.len())))?;
    w.write_all(&len.to_be_bytes())
        .await
        .map_err(|error| RelayStreamGuestError::Io(error.to_string()))?;
    w.write_all(payload)
        .await
        .map_err(|error| RelayStreamGuestError::Io(error.to_string()))?;
    w.flush()
        .await
        .map_err(|error| RelayStreamGuestError::Io(error.to_string()))?;
    Ok(())
}

async fn write_open_persistent_frame<W>(w: &mut W) -> Result<(), RelayStreamGuestError>
where
    W: AsyncWrite + Unpin,
{
    write_raw_frame(w, &[OPEN_PERSISTENT_FRAME]).await
}

/// Send `OpenPersistent` and await its ack: the server answers with
/// `TunnelFrame::Open` (0x10) or a typed `TunnelFrame::Error`.
///
/// The vendored crate now offers its own `client_open_persistent_stream`, and
/// `TunnelFrame::OpenPersistent` encodes to the same bytes this writes, so
/// neither direction requires a local raw path any more. This one is kept
/// because it emits the identical frame and the tests below pin that
/// equivalence; collapsing onto the vendored helper is a separate change with
/// its own diff, not a rider on the pin move.
async fn client_open_persistent_stream<S>(stream: &mut S) -> Result<(), RelayStreamGuestError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    write_open_persistent_frame(stream).await?;
    match recv_frame(stream).await? {
        TunnelFrame::Open => Ok(()),
        TunnelFrame::Error(reason) => Err(RelayStreamGuestError::AuthRejected(reason)),
        _ => Err(RelayStreamGuestError::Io(
            "expected open-persistent ack".to_string(),
        )),
    }
}

async fn receive_ip_tunnel_network_settings<S>(
    stream: &mut S,
    auth_mtu: u16,
    auth_session_id: &str,
    timeout: Duration,
) -> Result<RelayStreamGuestSessionMetadata, RelayStreamGuestError>
where
    S: AsyncRead + Unpin,
{
    let frame = tokio::time::timeout(timeout, recv_frame(stream))
        .await
        .map_err(|_| {
            RelayStreamGuestError::DataTunnel("post-open network settings timed out".to_string())
        })??;
    let TunnelFrame::NetworkSettings(settings) = frame else {
        return Err(RelayStreamGuestError::DataTunnel(
            "expected post-open network settings".to_string(),
        ));
    };
    // The frame carries an OPAQUE body, not a decoded struct, so decoding is a
    // step this guest performs rather than something the wire type guarantees.
    //
    // ORDER IS LOAD-BEARING: strict decode runs BEFORE any validation. It is the
    // only place a malformed body is rejected — every check in
    // `validate_ip_tunnel_network_settings` reads already-typed fields and so
    // cannot see a body that never parsed. Decoding later, or leniently, would
    // let a peer-supplied body reach the validators in a shape they do not
    // model.
    //
    // Propagated, not re-worded: the decoder already collapses every parse
    // failure to a fixed `InvalidFrame("bad network_settings frame")` that
    // carries none of the peer's bytes, so forwarding it keeps the upstream
    // classification instead of flattening it into a local string.
    let settings = decode_network_settings_body(&settings)?;
    validate_ip_tunnel_network_settings(settings, auth_mtu, auth_session_id)
}

fn validate_ip_tunnel_network_settings(
    settings: NetworkSettings,
    auth_mtu: u16,
    auth_session_id: &str,
) -> Result<RelayStreamGuestSessionMetadata, RelayStreamGuestError> {
    validate_session_identity(settings.mtu, &settings.session_id)?;
    if settings.mtu != auth_mtu || settings.session_id != auth_session_id {
        return Err(RelayStreamGuestError::DataTunnel(
            "post-open settings do not match authenticated session".to_string(),
        ));
    }

    let addr = settings.mesh_ipv4.addr.parse::<Ipv4Addr>().map_err(|_| {
        RelayStreamGuestError::DataTunnel("network settings address invalid".to_string())
    })?;
    let peer = settings.mesh_ipv4.peer.parse::<Ipv4Addr>().map_err(|_| {
        RelayStreamGuestError::DataTunnel("network settings peer invalid".to_string())
    })?;
    let prefix_len = settings.mesh_ipv4.prefix_len;
    if !(1..=31).contains(&prefix_len) {
        return Err(RelayStreamGuestError::DataTunnel(
            "network settings prefix invalid".to_string(),
        ));
    }

    let addr_raw = u32::from(addr);
    let peer_raw = u32::from(peer);
    let mask = u32::MAX << (32 - u32::from(prefix_len));
    let network = addr_raw & mask;
    let broadcast = network | !mask;
    let reserves_network_and_broadcast = prefix_len <= 30;
    if addr_raw == peer_raw
        || !usable_ipv4_unicast(addr_raw)
        || !usable_ipv4_unicast(peer_raw)
        || peer_raw & mask != network
        || (reserves_network_and_broadcast
            && (addr_raw == network
                || addr_raw == broadcast
                || peer_raw == network
                || peer_raw == broadcast))
    {
        return Err(RelayStreamGuestError::DataTunnel(
            "network settings route scope invalid".to_string(),
        ));
    }

    Ok(RelayStreamGuestSessionMetadata {
        mesh_ipv4: Some(RelayStreamGuestIpv4Metadata {
            addr: addr.to_string(),
            prefix_len,
            peer: peer.to_string(),
        }),
        mesh_ipv6: None,
        mtu: settings.mtu,
        session_id: settings.session_id,
    })
}

fn validate_session_identity(mtu: u16, session_id: &str) -> Result<(), RelayStreamGuestError> {
    if !(1280..=9000).contains(&mtu) {
        return Err(RelayStreamGuestError::DataTunnel(
            "session mtu invalid".to_string(),
        ));
    }
    if session_id.trim().is_empty()
        || session_id.trim() != session_id
        || !session_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_'))
    {
        return Err(RelayStreamGuestError::DataTunnel(
            "session id invalid".to_string(),
        ));
    }
    Ok(())
}

fn usable_ipv4_unicast(address: u32) -> bool {
    let first_octet = address >> 24;
    let first_two_octets = address >> 16;
    address != 0
        && address != u32::MAX
        && first_octet != 0
        && first_octet != 127
        && first_two_octets != 0xA9FE
        && first_octet < 224
}

pub async fn send_data<S>(stream: &mut S, data: &[u8]) -> Result<(), RelayStreamGuestError>
where
    S: AsyncWrite + Unpin,
{
    send_frame(stream, &TunnelFrame::Data(data.to_vec())).await?;
    Ok(())
}

pub async fn send_resize<S>(
    stream: &mut S,
    cols: u16,
    rows: u16,
) -> Result<(), RelayStreamGuestError>
where
    S: AsyncWrite + Unpin,
{
    client_resize(stream, cols, rows).await?;
    Ok(())
}

pub async fn send_close<S>(stream: &mut S) -> Result<(), RelayStreamGuestError>
where
    S: AsyncWrite + Unpin,
{
    send_frame(stream, &TunnelFrame::Close).await?;
    Ok(())
}

pub async fn recv_guest_frame<S>(
    stream: &mut S,
) -> Result<RelayStreamGuestFrame, RelayStreamGuestError>
where
    S: AsyncRead + Unpin,
{
    let frame = recv_frame(stream).await?;
    Ok(match frame {
        TunnelFrame::Health(bytes) => RelayStreamGuestFrame::Health(bytes),
        TunnelFrame::Open => RelayStreamGuestFrame::Open,
        TunnelFrame::Data(bytes) => RelayStreamGuestFrame::Data(bytes),
        TunnelFrame::Close => RelayStreamGuestFrame::Close,
        TunnelFrame::Error(reason) => RelayStreamGuestFrame::Error(reason),
        TunnelFrame::Window(n) => RelayStreamGuestFrame::Window(n),
        TunnelFrame::Resize { cols, rows } => {
            RelayStreamGuestFrame::Error(format!("unexpected resize frame {cols}x{rows}"))
        }
        TunnelFrame::Exit(TargetExit::Code(code)) => RelayStreamGuestFrame::ExitCode(code),
        TunnelFrame::Exit(TargetExit::Signal(signal)) => RelayStreamGuestFrame::ExitSignal(signal),
        TunnelFrame::Exit(TargetExit::Lost) => RelayStreamGuestFrame::ExitLost,
        TunnelFrame::NetworkSettings(_) => {
            RelayStreamGuestFrame::Error("unexpected network settings frame".to_string())
        }
        // `OpenPersistent` is a REQUEST this client sends; it is never something
        // a well-behaved peer sends back. Reaching this arm means the far side
        // emitted a client-role frame on the guest's read path, so it is
        // reported as an error rather than mapped onto `Open` — treating it as
        // an ack would let a peer satisfy an open handshake with the wrong
        // frame. Refused explicitly, matching the `Resize` precedent above,
        // rather than via a `_` arm, so a future variant still forces a
        // decision here instead of silently landing in a catch-all.
        TunnelFrame::OpenPersistent => {
            RelayStreamGuestFrame::Error("unexpected open-persistent frame".to_string())
        }
    })
}

fn decode_canonical_offer(
    offer_cbor: &[u8],
) -> Result<RelayStreamOfferContract, RelayStreamGuestError> {
    let offer = RelayStreamOfferContract::from_canonical_bytes(offer_cbor)
        .map_err(|error| RelayStreamGuestError::Offer(error.to_string()))?;
    let recoded = offer
        .to_canonical_bytes()
        .map_err(|error| RelayStreamGuestError::Cbor(error.to_string()))?;
    if recoded != offer_cbor {
        return Err(RelayStreamGuestError::Offer(
            "offer CBOR was not canonical".to_string(),
        ));
    }
    Ok(offer)
}

fn verify_offer_for_relay_stream(
    offer: &RelayStreamOfferContract,
    owner: &P256PublicKey,
    guest: &P256PublicKey,
    now_unix: u64,
) -> Result<(), RelayStreamGuestError> {
    offer
        .verify_for_audience(owner, guest, now_unix)
        .map_err(|error| RelayStreamGuestError::Offer(error.to_string()))?;
    if offer.payload.expected_path != RelayStreamExpectedPath::RelayStream {
        return Err(RelayStreamGuestError::Offer(
            "expected_path must be relay_stream".to_string(),
        ));
    }
    Ok(())
}

fn verify_credential_binding(
    credential_cbor: &[u8],
    offer: &RelayStreamOfferContract,
    owner: &P256PublicKey,
    guest: &P256PublicKey,
) -> Result<(), RelayStreamGuestError> {
    let credential: GuestCredential = cbor::from_canonical_slice(credential_cbor)
        .map_err(|error| RelayStreamGuestError::Credential(error.to_string()))?;
    let recoded = cbor::to_canonical_vec(&credential)
        .map_err(|error| RelayStreamGuestError::Cbor(error.to_string()))?;
    if recoded != credential_cbor {
        return Err(RelayStreamGuestError::Credential(
            "credential CBOR was not canonical".to_string(),
        ));
    }
    if credential.owner_p_pub != *owner {
        return Err(RelayStreamGuestError::Credential(
            "owner key mismatch".to_string(),
        ));
    }
    if credential.guest_device_pub != *guest {
        return Err(RelayStreamGuestError::Credential(
            "guest key mismatch".to_string(),
        ));
    }
    if credential.claw_id != offer.payload.claw_id {
        return Err(RelayStreamGuestError::Credential(
            "claw id mismatch".to_string(),
        ));
    }
    if credential.slot_id != offer.payload.slot_id {
        return Err(RelayStreamGuestError::Credential(
            "slot id mismatch".to_string(),
        ));
    }
    // Resources a guest may terminate on the DEVICE/credential path: a
    // terminal, or a shared app rendered in a web view. Both are owner-signed
    // byte streams over identical framing; which surface consumes them is
    // decided above this layer.
    //
    // ClawSite belongs here because the invite/claim flow provisions a DEVICE
    // offer (`try_provision_relay_stream_offer_for_claim`), so a claimed app
    // share is Device+credential. Refusing it would mean an invite can hand a
    // friend a full terminal but not a read-only page — the more dangerous
    // capability allowed and the harmless one blocked.
    //
    // `IpTunnel` stays refused: its data path is gated separately and demands
    // a Group audience, which this function does not check.
    //
    // Matched exhaustively, no `_` arm, so bumping the vendored household-rs
    // pin makes a new variant a compile error instead of silently admitting it.
    match offer.payload.resource {
        RelayStreamResource::Pty | RelayStreamResource::ClawSite => {}
        RelayStreamResource::IpTunnel => {
            return Err(RelayStreamGuestError::Credential(
                "credential auth does not support ip_tunnel resource".to_string(),
            ));
        }
    }
    if offer.payload.not_after > credential.expires_at {
        return Err(RelayStreamGuestError::Credential(
            "offer expiry exceeds credential expiry".to_string(),
        ));
    }
    Ok(())
}

fn parse_public_key(bytes: &[u8]) -> Result<P256PublicKey, RelayStreamGuestError> {
    P256PublicKey::from_bytes(bytes).map_err(|_| RelayStreamGuestError::PublicKeyMalformed)
}

fn parse_signature(bytes: &[u8]) -> Result<P256Signature, RelayStreamGuestError> {
    P256Signature::from_bytes(bytes).map_err(|_| RelayStreamGuestError::SignatureMalformed)
}

fn token_signing_bytes(
    session_id: &str,
    auth_material_cbor: &[u8],
    endpoint: &str,
    target_id: &str,
    nonce: &[u8],
    expires_at: u64,
    guest_public_key: P256PublicKey,
) -> Result<Vec<u8>, RelayStreamGuestError> {
    let captured = Arc::new(Mutex::new(None));
    let key = CapturingIdentityKey {
        public_key: guest_public_key,
        captured: Arc::clone(&captured),
    };
    let _ = SessionAuthToken::sign(
        session_id.to_string(),
        auth_material_cbor,
        endpoint.to_string(),
        target_id.to_string(),
        nonce.to_vec(),
        expires_at,
        &key,
    )?;
    captured
        .lock()
        .expect("capture mutex poisoned")
        .take()
        .ok_or_else(|| RelayStreamGuestError::Cbor("token signing bytes missing".to_string()))
}

fn signed_session_auth_token(
    request: &RelayStreamAuthSigningRequest,
    signature: &[u8],
) -> Result<SessionAuthToken, RelayStreamGuestError> {
    let guest_public_key = parse_public_key(&request.guest_device_pub)?;
    let signature = parse_signature(signature)?;
    verify_signature(&guest_public_key, &request.signing_bytes, &signature)
        .map_err(|_| RelayStreamGuestError::SignatureRejected)?;

    let key = InjectedSignatureIdentityKey {
        public_key: guest_public_key,
        signature,
        expected_signing_bytes: request.signing_bytes.clone(),
    };
    SessionAuthToken::sign(
        request.session_id.clone(),
        &request.auth_material_cbor,
        request.endpoint.clone(),
        request.target_id.clone(),
        request.nonce.clone(),
        request.expires_at,
        &key,
    )
    .map_err(Into::into)
}

struct CapturingIdentityKey {
    public_key: P256PublicKey,
    captured: Arc<Mutex<Option<Vec<u8>>>>,
}

impl IdentityKey for CapturingIdentityKey {
    fn public(&self) -> P256PublicKey {
        self.public_key.clone()
    }

    fn sign(&self, message: &[u8]) -> Result<P256Signature, KeystoreError> {
        *self.captured.lock().expect("capture mutex poisoned") = Some(message.to_vec());
        P256Signature::from_bytes(&[0u8; P256Signature::LEN])
            .map_err(|error| KeystoreError::InvalidKeyMaterial(error.to_string()))
    }

    fn backing(&self) -> &'static str {
        "ffi-capture"
    }
}

struct InjectedSignatureIdentityKey {
    public_key: P256PublicKey,
    signature: P256Signature,
    expected_signing_bytes: Vec<u8>,
}

impl IdentityKey for InjectedSignatureIdentityKey {
    fn public(&self) -> P256PublicKey {
        self.public_key.clone()
    }

    fn sign(&self, message: &[u8]) -> Result<P256Signature, KeystoreError> {
        if message != self.expected_signing_bytes {
            return Err(KeystoreError::InvalidKeyMaterial(
                "token signing bytes drifted".to_string(),
            ));
        }
        Ok(self.signature.clone())
    }

    fn backing(&self) -> &'static str {
        "ffi-injected-signature"
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use household_rs::claw_share::{ClawShareSlotStore, SlotId, SlotRecord, SlotState};
    use household_rs::claw_share_data_tunnel::{
        ClawTargetRouter, DataTunnelSession, MeshIpv4, ReplayGuard, TargetSession,
        authorize_session, encode_network_settings_body, serve_connection_io,
        serve_connection_io_with_auth_deadline,
    };
    use household_rs::claw_share_relay_stream_contract::{
        RelayStreamOfferContract, RelayStreamOfferMintInput, RelayStreamResource,
        mint_relay_stream_offer,
    };
    use household_rs::claw_share_relay_stream_noise::{
        RelayStreamNoiseFramed, generate_relay_stream_noise_static_keypair,
    };
    use household_rs::ids::derive_household_id;
    use household_rs::keys::P256Keypair;
    use household_rs::person_cert::derive_person_id;
    use tokio::io::{AsyncReadExt, AsyncWriteExt, duplex};
    use tokio::net::TcpListener;

    use super::*;

    const NOW: u64 = 1_800_000_000;
    const NOT_AFTER: u64 = NOW + 60;

    struct Fixture {
        owner: P256Keypair,
        guest: P256Keypair,
        credential: GuestCredential,
        offer: RelayStreamOfferContract,
        noise_keypair: household_rs::claw_share_relay_stream_noise::RelayStreamNoiseStaticKeypair,
    }

    impl Fixture {
        fn new() -> Self {
            Self::new_with_endpoint("relay-stream://127.0.0.1:49152".to_string())
        }

        fn new_with_endpoint(relay_endpoint: String) -> Self {
            let owner = P256Keypair::from_secret_scalar(&[0x11; 32]).expect("owner key");
            let guest = P256Keypair::from_secret_scalar(&[0x33; 32]).expect("guest key");
            let hh_id = derive_household_id(&owner.public());
            let owner_p_id = derive_person_id(&owner.public());
            let slot_id = SlotId([0x22; 16]);
            let credential = GuestCredential::sign(
                hh_id,
                owner_p_id,
                owner.public(),
                "claw_alpha".to_string(),
                guest.public(),
                slot_id,
                NOW,
                NOW + 3600,
                &owner,
            )
            .expect("credential");
            let noise_keypair =
                generate_relay_stream_noise_static_keypair().expect("noise keypair");
            let offer = mint_relay_stream_offer(
                RelayStreamOfferMintInput {
                    rendezvous_token:
                        household_rs::claw_share_rendezvous_token::RendezvousToken::try_new(
                            vec![0x42; 16],
                        )
                        .expect("token"),
                    credential: &credential,
                    resource: RelayStreamResource::Pty,
                    expected_path: RelayStreamExpectedPath::RelayStream,
                    relay_endpoint,
                    claw_static_pub: noise_keypair.public_key().clone(),
                    app_presentation: None,
                    not_after: NOT_AFTER,
                    now_unix: NOW,
                },
                &owner,
            )
            .expect("offer");
            Self {
                owner,
                guest,
                credential,
                offer,
                noise_keypair,
            }
        }

        fn offer_cbor(&self) -> Vec<u8> {
            self.offer.to_canonical_bytes().expect("offer cbor")
        }

        fn credential_cbor(&self) -> Vec<u8> {
            cbor::to_canonical_vec(&self.credential).expect("credential cbor")
        }

        fn offer_cbor_with(
            &self,
            edit: impl FnOnce(
                &mut household_rs::claw_share_relay_stream_contract::RelayStreamOfferPayload,
            ),
        ) -> Vec<u8> {
            let mut payload = self.offer.payload.clone();
            edit(&mut payload);
            RelayStreamOfferContract::sign(payload, &self.owner)
                .expect("mutated offer")
                .to_canonical_bytes()
                .expect("mutated offer cbor")
        }

        fn consumed_store(&self) -> Arc<ClawShareSlotStore> {
            let store = ClawShareSlotStore::new();
            store
                .insert(SlotRecord {
                    slot_id: self.credential.slot_id.clone(),
                    claw_id: self.credential.claw_id.clone(),
                    expires_at: self.credential.expires_at,
                    state: SlotState::Consumed {
                        guest_device_pub: self.credential.guest_device_pub.clone(),
                        consumed_at: NOW,
                    },
                    // Both `None`: this fixture exercises the tunnel, not the
                    // owner-facing presentation, and `created_at` is documented
                    // upstream as never synthesized — an invented mint time
                    // would be indistinguishable from an observed one.
                    app_presentation: None,
                    created_at: None,
                })
                .expect("slot insert");
            Arc::new(store)
        }
    }

    struct EchoRouter;

    impl ClawTargetRouter for EchoRouter {
        async fn open(&self, _target_id: &str) -> Result<TargetSession, DataTunnelError> {
            let (server_side, mut target_side) = duplex(4096);
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                while let Ok(n) = target_side.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    if target_side.write_all(b"ACK:").await.is_err() {
                        break;
                    }
                    if target_side.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                    let _ = target_side.flush().await;
                }
            });
            Ok(TargetSession::from_stream(server_side))
        }
    }

    #[test]
    fn rendezvous_hello_uses_theyos_guest_codec() {
        let fixture = Fixture::new();
        let hello = rendezvous_hello_bytes(&fixture.offer_cbor()).expect("hello");
        let mut expected = vec![0x01, 0x01, 0x00, 0x10];
        expected.extend(vec![0x42; 16]);
        assert_eq!(hello, expected);
    }

    #[test]
    fn prepare_device_auth_pins_session_token_signing_bytes() {
        let fixture = Fixture::new();
        let request = prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor: fixture.offer_cbor(),
            credential_cbor: Some(fixture.credential_cbor()),
            expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
            expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "ios-relay-stream-fixture".to_string(),
            nonce: Some(vec![0x44; 16]),
        })
        .expect("prepare auth");

        const EXPECTED_SIGNING_HEX: &str = "a6656e6f6e6365504444444444444444444444444444444468656e64706f696e74781e72656c61792d73747265616d3a2f2f3132372e302e302e313a3439313532697461726765745f69646a636c61775f616c7068616a657870697265735f61741a6b49d23c6a73657373696f6e5f69647818696f732d72656c61792d73747265616d2d666978747572656f63726564656e7469616c5f686173685820ecc62b501421473996a0c265d7442d3ea69f0a0765202de66b50b916a2d53580";
        assert_eq!(hex::encode(&request.signing_bytes), EXPECTED_SIGNING_HEX);
        assert_eq!(request.auth_mode, RelayStreamAuthMode::DeviceCredential);

        let signature = fixture
            .guest
            .sign(&request.signing_bytes)
            .expect("guest sign");
        let envelope = encode_auth_envelope(&request, signature.as_bytes()).expect("auth envelope");
        let decoded: AuthEnvelope = cbor::from_canonical_slice(&envelope).expect("decode");
        decoded
            .token
            .verify(
                &fixture.guest.public(),
                &household_rs::claw_share_data_tunnel::credential_hash(&request.auth_material_cbor),
                NOW,
            )
            .expect("token verifies");
    }

    /// A ClawSite offer must survive credential binding exactly like a PTY
    /// one. This is the whole point of sharing an app by invite: the claim
    /// flow provisions a DEVICE offer, so if credential auth refused
    /// ClawSite, a friend could be handed a terminal but never a page.
    #[test]
    fn prepare_accepts_clawsite_credential_offer() {
        let fixture = Fixture::new();
        let request = prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor: fixture.offer_cbor_with(|payload| {
                payload.resource = RelayStreamResource::ClawSite;
            }),
            credential_cbor: Some(fixture.credential_cbor()),
            expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
            expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "ios-relay-stream-fixture".to_string(),
            nonce: Some(vec![0x44; 16]),
        })
        .expect("clawsite credential offer must prepare");
        assert_eq!(request.auth_mode, RelayStreamAuthMode::DeviceCredential);

        // The token still binds to the guest key and the credential, so
        // admitting the resource did not weaken the authentication itself.
        let signature = fixture
            .guest
            .sign(&request.signing_bytes)
            .expect("guest sign");
        let envelope = encode_auth_envelope(&request, signature.as_bytes()).expect("auth envelope");
        let decoded: AuthEnvelope = cbor::from_canonical_slice(&envelope).expect("decode");
        decoded
            .token
            .verify(
                &fixture.guest.public(),
                &household_rs::claw_share_data_tunnel::credential_hash(&request.auth_material_cbor),
                NOW,
            )
            .expect("token verifies");
    }

    #[test]
    fn prepare_rejects_device_offer_without_credential() {
        let fixture = Fixture::new();
        let error = prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor: fixture.offer_cbor(),
            credential_cbor: None,
            expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
            expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "ios-relay-stream-fixture".to_string(),
            nonce: Some(vec![0x44; 16]),
        })
        .unwrap_err();
        assert!(matches!(error, RelayStreamGuestError::AuthMode(_)));
    }

    #[test]
    fn prepare_rejects_credential_offer_binding_mismatches() {
        let fixture = Fixture::new();

        for (offer_cbor, expected) in [
            (
                fixture.offer_cbor_with(|payload| {
                    payload.claw_id = "claw_beta".to_string();
                }),
                "claw id mismatch",
            ),
            (
                fixture.offer_cbor_with(|payload| {
                    payload.slot_id = SlotId([0x23; 16]);
                }),
                "slot id mismatch",
            ),
            // ClawSite is no longer a row here: it is a legitimate resource on
            // the credential path, because the invite/claim flow provisions a
            // DEVICE offer. `IpTunnel` takes its place as the resource this
            // function must refuse. The ClawSite positive case is
            // `prepare_accepts_clawsite_credential_offer`.
            (
                fixture.offer_cbor_with(|payload| {
                    payload.resource = RelayStreamResource::IpTunnel;
                }),
                "credential auth does not support ip_tunnel resource",
            ),
            (
                fixture.offer_cbor_with(|payload| {
                    payload.not_after = fixture.credential.expires_at + 1;
                }),
                "offer expiry exceeds credential expiry",
            ),
        ] {
            let error = prepare_auth_signing_request(RelayStreamPrepareAuthInput {
                offer_cbor,
                credential_cbor: Some(fixture.credential_cbor()),
                expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
                expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
                now_unix: NOW,
                ttl_secs: 60,
                session_id: "ios-relay-stream-fixture".to_string(),
                nonce: Some(vec![0x44; 16]),
            })
            .unwrap_err();
            assert!(
                matches!(&error, RelayStreamGuestError::Credential(message) if message == expected),
                "expected credential binding error {expected}, got {error:?}"
            );
        }
    }

    #[test]
    fn encode_auth_envelope_rejects_wrong_signature() {
        let fixture = Fixture::new();
        let request = prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor: fixture.offer_cbor(),
            credential_cbor: Some(fixture.credential_cbor()),
            expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
            expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "ios-relay-stream-fixture".to_string(),
            nonce: Some(vec![0x44; 16]),
        })
        .expect("prepare auth");
        let other = P256Keypair::from_secret_scalar(&[0x55; 32]).expect("other key");
        let signature = other.sign(&request.signing_bytes).expect("sign");
        let error = encode_auth_envelope(&request, signature.as_bytes()).unwrap_err();
        assert!(matches!(error, RelayStreamGuestError::SignatureRejected));
    }

    #[tokio::test]
    async fn device_offer_noise_auth_open_and_data_round_trip() {
        let fixture = Fixture::new();
        let offer_cbor = fixture.offer_cbor();
        let credential_cbor = fixture.credential_cbor();
        let (client_io, server_io) = duplex(1 << 16);

        let server_offer = fixture.offer.clone();
        let server_owner = fixture.owner.public();
        let slot_store = fixture.consumed_store();
        let server_noise_keypair = fixture.noise_keypair;
        let rev_store = Arc::clone(&slot_store);
        let household_id = derive_household_id(&fixture.owner.public());
        let replay = Arc::new(ReplayGuard::new());
        let router = Arc::new(EchoRouter);

        let server = tokio::spawn(async move {
            let prologue = server_offer
                .to_noise_prologue_owner_verified(&server_owner, NOW)
                .expect("prologue");
            let framed = RelayStreamNoiseFramed::responder_handshake_with_prologue(
                server_io,
                &prologue,
                server_noise_keypair.private_key(),
            )
            .await
            .expect("responder handshake");
            let noise_stream = framed.into_async_stream();
            let auth_slots = Arc::clone(&slot_store);
            let auth_replay = Arc::clone(&replay);
            serve_connection_io(
                noise_stream,
                NOW,
                move |envelope, now| {
                    authorize_session(envelope, &household_id, &auth_slots, &auth_replay, now)
                },
                router.as_ref(),
                move |credential| {
                    matches!(
                        rev_store
                            .get(&credential.slot_id)
                            .map(|record| record.state),
                        Some(SlotState::Revoked { .. })
                    )
                },
            )
            .await
            .expect("serve connection");
        });

        let client_noise = initiate_noise_on_stream(
            client_io,
            &offer_cbor,
            fixture.owner.public().as_bytes(),
            fixture.guest.public().as_bytes(),
            NOW,
        )
        .await
        .expect("initiator handshake");

        let request = prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor,
            credential_cbor: Some(credential_cbor),
            expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
            expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "ios-relay-stream-roundtrip".to_string(),
            nonce: Some(vec![0x45; 16]),
        })
        .expect("prepare auth");
        let signature = fixture
            .guest
            .sign(&request.signing_bytes)
            .expect("guest sign");
        let mut stream = authenticate_health_open(client_noise, &request, signature.as_bytes())
            .await
            .expect("auth/open");

        send_data(&mut stream, b"ping").await.expect("send data");
        assert_eq!(
            recv_guest_frame(&mut stream).await.expect("recv data"),
            RelayStreamGuestFrame::Data(b"ACK:ping".to_vec())
        );
        send_resize(&mut stream, 80, 24).await.expect("resize");
        send_close(&mut stream).await.expect("close");
        server.await.expect("server task");
    }

    #[tokio::test]
    async fn ffi_connect_opens_session_and_receives_data() {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind listener");
        let endpoint = format!(
            "relay-stream://{}",
            listener.local_addr().expect("listener addr")
        );
        let fixture = Fixture::new_with_endpoint(endpoint);
        let offer_cbor = fixture.offer_cbor();
        let credential_cbor = fixture.credential_cbor();

        let server_offer = fixture.offer.clone();
        let server_owner = fixture.owner.public();
        let slot_store = fixture.consumed_store();
        let server_noise_keypair = fixture.noise_keypair;
        let rev_store = Arc::clone(&slot_store);
        let household_id = derive_household_id(&fixture.owner.public());
        let replay = Arc::new(ReplayGuard::new());
        let router = Arc::new(EchoRouter);
        let expected_hello = RendezvousHello::new(
            RendezvousRole::Guest,
            fixture.offer.payload.rendezvous_token.clone(),
        )
        .encode();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept client");
            let mut actual_hello = vec![0u8; expected_hello.len()];
            socket
                .read_exact(&mut actual_hello)
                .await
                .expect("read hello");
            assert_eq!(actual_hello, expected_hello);

            let prologue = server_offer
                .to_noise_prologue_owner_verified(&server_owner, NOW)
                .expect("prologue");
            let framed = RelayStreamNoiseFramed::responder_handshake_with_prologue(
                socket,
                &prologue,
                server_noise_keypair.private_key(),
            )
            .await
            .expect("responder handshake");
            let noise_stream = framed.into_async_stream();
            let auth_slots = Arc::clone(&slot_store);
            let auth_replay = Arc::clone(&replay);
            serve_connection_io(
                noise_stream,
                NOW,
                move |envelope, now| {
                    authorize_session(envelope, &household_id, &auth_slots, &auth_replay, now)
                },
                router.as_ref(),
                move |credential| {
                    matches!(
                        rev_store
                            .get(&credential.slot_id)
                            .map(|record| record.state),
                        Some(SlotState::Revoked { .. })
                    )
                },
            )
            .await
            .expect("serve connection");
        });

        let request = relay_stream_prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor: offer_cbor.clone(),
            credential_cbor: Some(credential_cbor),
            expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
            expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "ios-relay-stream-ffi".to_string(),
            nonce: Some(vec![0x46; 16]),
        })
        .expect("prepare auth");
        let signature = fixture
            .guest
            .sign(&request.signing_bytes)
            .expect("guest sign")
            .as_bytes()
            .to_vec();
        let session = relay_stream_connect(
            offer_cbor,
            fixture.owner.public().as_bytes().to_vec(),
            fixture.guest.public().as_bytes().to_vec(),
            request,
            signature,
            NOW,
            1_000,
        )
        .await
        .expect("connect session");

        let read_session = Arc::clone(&session);
        let read_task = tokio::spawn(async move { read_session.read_frame().await });
        tokio::time::sleep(Duration::from_millis(25)).await;
        session
            .send_data(b"ping".to_vec())
            .await
            .expect("send while read is pending");
        assert_eq!(
            read_task.await.expect("read task").expect("recv"),
            RelayStreamGuestFrameRecord {
                kind: RelayStreamGuestFrameKind::Data,
                data: b"ACK:ping".to_vec(),
                number: 0,
                text: String::new(),
            }
        );
        session.send_close().await.expect("close");
        server.await.expect("server task");
    }

    #[tokio::test]
    async fn ffi_session_preserves_fragmented_inbound_frame_while_sending() {
        let (client_io, server_io) = duplex(4096);
        let (client_read, client_write) = tokio::io::split(client_io);
        let (mut server_read, mut server_write) = tokio::io::split(server_io);
        let (command_tx, command_rx) = mpsc::channel(32);
        let (frame_tx, frame_rx) = mpsc::channel(32);
        tokio::spawn(drive_guest_writer(client_write, command_rx, false));
        tokio::spawn(drive_guest_reader(client_read, frame_tx));
        let session = Arc::new(RelayStreamGuestSession {
            command_tx,
            frame_rx: TokioMutex::new(frame_rx),
            metadata: RelayStreamGuestSessionMetadata {
                mesh_ipv4: None,
                mesh_ipv6: Some("fd00::10".to_string()),
                mtu: 1280,
                session_id: "session-test".to_string(),
            },
            target_open: TokioMutex::new(true),
            target_operation: TokioMutex::new(()),
            persistent: false,
        });

        let payload = TunnelFrame::Data(b"ACK:fragment".to_vec()).encode();
        let mut raw_frame = Vec::with_capacity(4 + payload.len());
        raw_frame.extend_from_slice(
            &u32::try_from(payload.len())
                .expect("payload len fits")
                .to_be_bytes(),
        );
        raw_frame.extend_from_slice(&payload);
        server_write
            .write_all(&raw_frame[..2])
            .await
            .expect("write partial frame length");
        server_write.flush().await.expect("flush partial length");

        let read_session = Arc::clone(&session);
        let read_task = tokio::spawn(async move { read_session.read_frame().await });
        tokio::time::sleep(Duration::from_millis(25)).await;
        session
            .send_data(b"ping".to_vec())
            .await
            .expect("send while partial inbound frame is pending");
        assert_eq!(
            recv_frame(&mut server_read)
                .await
                .expect("recv client input"),
            TunnelFrame::Data(b"ping".to_vec())
        );

        server_write
            .write_all(&raw_frame[2..])
            .await
            .expect("finish fragmented frame");
        server_write.flush().await.expect("flush full frame");
        assert_eq!(
            read_task.await.expect("read task").expect("recv"),
            RelayStreamGuestFrameRecord {
                kind: RelayStreamGuestFrameKind::Data,
                data: b"ACK:fragment".to_vec(),
                number: 0,
                text: String::new(),
            }
        );
        session.send_close().await.expect("close");
    }

    // ─── OpenPersistent (0x18) ──────────────────────────────────────────────
    //
    // 0x18 IS in this crate's vendored `TunnelFrame` as of rev
    // 43a517f0d8b527130ca734e4e1727190e96b04f0 (re-exported from
    // `tunnel-wire-rs`), but `serve_connection_io` above still does not serve
    // it, so these tests keep exercising the client against a hand-rolled
    // LOCAL DOUBLE (`serve_persistent_double`).
    //
    // The double's wire shape was re-diffed against the landed form: bare 0x18
    // request, legacy `TunnelFrame::Open` as the stream-ready ack, and the
    // `session-open-budget-exhausted` rejection string, all confirmed present
    // in the landed server. The budget rejection IS modelled below. Two landed
    // paths are NOT: `persistent-target-not-authorized`, and the
    // post-negotiation ban on a legacy `Open`.
    //
    // This remains NOT a claim that the real engine has been exercised: the
    // double is a local-only stand-in. Serving 0x18 from `serve_connection_io`
    // against the vendored enum is now possible and would make these tests
    // real; it is deliberately left as a separate change.

    /// Read one raw length-prefixed frame (`u32` BE length + payload),
    /// mirroring the private wire envelope in
    /// `household_rs::claw_share_data_tunnel`. Test-only: it lets the double
    /// assert the exact bytes on the wire. Production client code reads acks
    /// through the vendored `recv_frame`, which decodes `OpenPersistent`
    /// (0x18); this raw reader exists so the double can inspect exact bytes.
    async fn read_raw_frame<R>(r: &mut R) -> Vec<u8>
    where
        R: AsyncReadExt + Unpin,
    {
        let mut len_buf = [0u8; 4];
        r.read_exact(&mut len_buf)
            .await
            .expect("read raw frame length");
        let n = u32::from_be_bytes(len_buf) as usize;
        let mut buf = vec![0u8; n];
        r.read_exact(&mut buf).await.expect("read raw frame body");
        buf
    }

    /// Serve `targets` sequential `OpenPersistent` cycles on one already
    /// Noise-authenticated stream: auth always accepts (that logic is
    /// exercised elsewhere, via the real vendored `serve_connection_io`),
    /// health is echoed once, then each target's frame must be a bare
    /// `[OPEN_PERSISTENT_FRAME]`, acked with the legacy `TunnelFrame::Open`
    /// (matching the real contract: the ack opcode never changes), and its
    /// `Data` is echoed `ACK:`-prefixed until the client sends `Close`.
    async fn serve_persistent_double<S>(mut stream: S, targets: usize)
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let _envelope = read_raw_frame(&mut stream).await;
        let ack = TunnelAck::Ok {
            mesh_ipv6: "fd00::10".to_string(),
            mtu: 1280,
            session_id: "persistent-test-session".to_string(),
        };
        let ack_bytes = cbor::to_canonical_vec(&ack).expect("encode ack");
        write_raw_frame(&mut stream, &ack_bytes)
            .await
            .expect("write ack");

        match recv_frame(&mut stream).await.expect("recv health") {
            TunnelFrame::Health(probe) => {
                send_frame(&mut stream, &TunnelFrame::Health(probe))
                    .await
                    .expect("echo health");
            }
            other => panic!("expected health, got {other:?}"),
        }

        for target_n in 0..targets {
            let open = read_raw_frame(&mut stream).await;
            assert_eq!(
                open,
                vec![OPEN_PERSISTENT_FRAME],
                "target {target_n}: expected a bare OpenPersistent(0x18) frame"
            );
            send_frame(&mut stream, &TunnelFrame::Open)
                .await
                .expect("open ack");

            loop {
                match recv_frame(&mut stream).await.expect("recv in target") {
                    TunnelFrame::Data(bytes) => {
                        let mut echoed = b"ACK:".to_vec();
                        echoed.extend_from_slice(&bytes);
                        send_frame(&mut stream, &TunnelFrame::Data(echoed))
                            .await
                            .expect("echo data");
                    }
                    TunnelFrame::Close => {
                        send_frame(&mut stream, &TunnelFrame::Close)
                            .await
                            .expect("close echo");
                        break;
                    }
                    other => panic!("target {target_n}: unexpected frame {other:?}"),
                }
            }
        }
    }

    #[tokio::test]
    async fn ffi_connect_persistent_reuses_the_noise_connection_across_two_targets() {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind listener");
        let endpoint = format!(
            "relay-stream://{}",
            listener.local_addr().expect("listener addr")
        );
        let fixture = Fixture::new_with_endpoint(endpoint);
        let offer_cbor = fixture.offer_cbor_with(|payload| {
            payload.resource = RelayStreamResource::ClawSite;
        });
        let credential_cbor = fixture.credential_cbor();
        let mutated_offer = RelayStreamOfferContract::from_canonical_bytes(&offer_cbor)
            .expect("decode mutated offer");

        let server_owner = fixture.owner.public();
        let server_noise_keypair = fixture.noise_keypair;
        let expected_hello = RendezvousHello::new(
            RendezvousRole::Guest,
            mutated_offer.payload.rendezvous_token.clone(),
        )
        .encode();
        let server_offer = mutated_offer.clone();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept client");
            let mut actual_hello = vec![0u8; expected_hello.len()];
            socket
                .read_exact(&mut actual_hello)
                .await
                .expect("read hello");
            assert_eq!(actual_hello, expected_hello);

            let prologue = server_offer
                .to_noise_prologue_owner_verified(&server_owner, NOW)
                .expect("prologue");
            let framed = RelayStreamNoiseFramed::responder_handshake_with_prologue(
                socket,
                &prologue,
                server_noise_keypair.private_key(),
            )
            .await
            .expect("responder handshake");
            serve_persistent_double(framed.into_async_stream(), 2).await;
        });

        let request = relay_stream_prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor: offer_cbor.clone(),
            credential_cbor: Some(credential_cbor),
            expected_owner_pub: fixture.owner.public().as_bytes().to_vec(),
            expected_guest_pub: fixture.guest.public().as_bytes().to_vec(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "ios-relay-stream-persistent".to_string(),
            nonce: Some(vec![0x47; 16]),
        })
        .expect("prepare auth");
        let signature = fixture
            .guest
            .sign(&request.signing_bytes)
            .expect("guest sign")
            .as_bytes()
            .to_vec();

        let session = relay_stream_connect_persistent(
            offer_cbor,
            fixture.owner.public().as_bytes().to_vec(),
            fixture.guest.public().as_bytes().to_vec(),
            request,
            signature,
            NOW,
            1_000,
        )
        .await
        .expect("connect persistent session");

        // Target 1, over the connection `relay_stream_connect_persistent`
        // just opened via 0x18 (not legacy 0x10 — the double asserts this).
        session
            .send_data(b"first".to_vec())
            .await
            .expect("send target 1");
        assert_eq!(
            session.read_frame().await.expect("recv target 1"),
            RelayStreamGuestFrameRecord {
                kind: RelayStreamGuestFrameKind::Data,
                data: b"ACK:first".to_vec(),
                number: 0,
                text: String::new(),
            }
        );
        // `send_close` drains the server's Close ack ITSELF (see its doc) —
        // asserting on `read_frame()` here would hang forever waiting for a
        // second frame the mock only ever sends one of.
        session.send_close().await.expect("close target 1");

        // Target 2: same Noise connection (the listener only ever accepted
        // ONE socket), no new signing, just `open_next_target` — which
        // likewise drains its own Open ack internally.
        session
            .open_next_target()
            .await
            .expect("open target 2 on the reused connection");
        session
            .send_data(b"nothing-leaked".to_vec())
            .await
            .expect("send target 2");
        // Proves the drain actually happened: the FIRST thing the bridge-
        // facing `read_frame()` sees for target 2 is real Data, never the
        // Open ack `open_next_target` already consumed.
        assert_eq!(
            session.read_frame().await.expect("recv target 2"),
            RelayStreamGuestFrameRecord {
                kind: RelayStreamGuestFrameKind::Data,
                data: b"ACK:nothing-leaked".to_vec(),
                number: 0,
                text: String::new(),
            }
        );
        session.send_close().await.expect("close target 2");

        server.await.expect("server task");
    }

    #[tokio::test]
    async fn open_next_target_is_rejected_locally_while_a_target_is_still_open() {
        let (client_io, server_io) = duplex(4096);
        let (client_read, client_write) = tokio::io::split(client_io);
        let (mut server_read, _server_write) = tokio::io::split(server_io);
        let (command_tx, command_rx) = mpsc::channel(32);
        let (frame_tx, frame_rx) = mpsc::channel(32);
        tokio::spawn(drive_guest_writer(client_write, command_rx, true));
        tokio::spawn(drive_guest_reader(client_read, frame_tx));
        let session = Arc::new(RelayStreamGuestSession {
            command_tx,
            frame_rx: TokioMutex::new(frame_rx),
            metadata: RelayStreamGuestSessionMetadata {
                mesh_ipv4: None,
                mesh_ipv6: Some("fd00::10".to_string()),
                mtu: 1280,
                session_id: "session-guard-test".to_string(),
            },
            // Matches the real post-connect state: one target already open.
            target_open: TokioMutex::new(true),
            target_operation: TokioMutex::new(()),
            persistent: true,
        });

        let result = session.open_next_target().await;
        assert!(
            matches!(result, Err(RelayStreamGuestError::DataTunnel(_))),
            "expected the local guard to reject a second open before close, got {result:?}"
        );

        // The guard must fire BEFORE anything reaches the wire: sending an
        // out-of-turn OpenPersistent is a framing violation for the real
        // server (it tears down the whole connection, not just the request).
        let mut probe = [0u8; 1];
        let read_result =
            tokio::time::timeout(Duration::from_millis(50), server_read.read(&mut probe)).await;
        assert!(
            read_result.is_err(),
            "local guard must reject before writing anything to the wire"
        );
    }

    #[tokio::test]
    async fn server_rejection_of_open_persistent_surfaces_as_an_error_frame_and_ends_the_session()
     {
        let (client_io, server_io) = duplex(4096);
        let (client_read, client_write) = tokio::io::split(client_io);
        let (mut server_read, mut server_write) = tokio::io::split(server_io);
        let (command_tx, command_rx) = mpsc::channel(32);
        let (frame_tx, frame_rx) = mpsc::channel(32);
        tokio::spawn(drive_guest_writer(client_write, command_rx, true));
        tokio::spawn(drive_guest_reader(client_read, frame_tx));
        let session = Arc::new(RelayStreamGuestSession {
            command_tx,
            frame_rx: TokioMutex::new(frame_rx),
            metadata: RelayStreamGuestSessionMetadata {
                mesh_ipv4: None,
                mesh_ipv6: Some("fd00::10".to_string()),
                mtu: 1280,
                session_id: "session-reset-test".to_string(),
            },
            target_open: TokioMutex::new(false),
            target_operation: TokioMutex::new(()),
            persistent: true,
        });

        // `open_next_target` now drains its own ack (see its doc) — it does
        // not return until the mock server has answered, so the response
        // must be produced concurrently rather than after.
        let responder = tokio::spawn(async move {
            let open = read_raw_frame(&mut server_read).await;
            assert_eq!(open, vec![OPEN_PERSISTENT_FRAME]);
            // Exact rejection string from the landed server contract at
            // 43a517f0d8b527130ca734e4e1727190e96b04f0
            // (`claw_share_data_tunnel.rs`, emitted once a session exceeds
            // `PERSISTENT_MAX_TARGET_OPENS`) — see
            // relay_stream_connect_persistent's provenance note.
            send_frame(
                &mut server_write,
                &TunnelFrame::Error("session-open-budget-exhausted".into()),
            )
            .await
            .expect("send rejection");
            // Reset: the real server drops the whole connection on
            // rejection (`return Err(...)`) — drop both halves to mirror
            // that once the rejection has been sent.
            drop(server_write);
            drop(server_read);
        });

        let result = session.open_next_target().await;
        match result {
            Err(RelayStreamGuestError::AuthRejected(reason)) => {
                assert_eq!(reason, "session-open-budget-exhausted");
            }
            other => panic!("expected the rejection to surface directly, got {other:?}"),
        }
        responder.await.expect("responder task");

        // The rejection must not be silently reusable: any further use of
        // the session fails rather than pretending the target opened.
        let after = session.read_frame().await;
        assert!(
            after.is_err(),
            "session must not be silently reusable after a server rejection, got {after:?}"
        );
    }

    #[tokio::test]
    async fn spontaneous_close_makes_send_close_a_noop_and_open_next_target_still_works() {
        // theyos 2ff5599aa76bb1fdbb390905d3d41fbfc6c33f8c's scenario: the
        // target ends on its own (the backend hung up) BEFORE the bridge
        // ever calls `close()` — e.g. the bridge's own `.closed`-before-
        // complete error path, which still calls `session.close()` on its
        // way out. A naive `send_close` would write a SECOND `Close` here;
        // the real server treats that redundant one as a no-op with no
        // second ack, so draining for one would hang forever.
        let (client_io, server_io) = duplex(4096);
        let (client_read, client_write) = tokio::io::split(client_io);
        let (mut server_read, mut server_write) = tokio::io::split(server_io);
        let (command_tx, command_rx) = mpsc::channel(32);
        let (frame_tx, frame_rx) = mpsc::channel(32);
        tokio::spawn(drive_guest_writer(client_write, command_rx, true));
        tokio::spawn(drive_guest_reader(client_read, frame_tx));
        let session = Arc::new(RelayStreamGuestSession {
            command_tx,
            frame_rx: TokioMutex::new(frame_rx),
            metadata: RelayStreamGuestSessionMetadata {
                mesh_ipv4: None,
                mesh_ipv6: Some("fd00::10".to_string()),
                mtu: 1280,
                session_id: "session-spontaneous-close-test".to_string(),
            },
            target_open: TokioMutex::new(true),
            target_operation: TokioMutex::new(()),
            persistent: true,
        });

        send_frame(&mut server_write, &TunnelFrame::Close)
            .await
            .expect("send spontaneous close");
        let observed = session.read_frame().await.expect("recv spontaneous close");
        assert_eq!(observed.kind, RelayStreamGuestFrameKind::Close);

        // Idempotent: returns immediately, and writes NOTHING — proven by a
        // bounded read on the server side seeing no further bytes at all.
        session.send_close().await.expect("idempotent close");
        let mut probe = [0u8; 1];
        let saw_a_second_write =
            tokio::time::timeout(Duration::from_millis(50), server_read.read(&mut probe)).await;
        assert!(
            saw_a_second_write.is_err(),
            "send_close must not write a second Close once the target already ended"
        );

        // The connection itself is still perfectly usable — open_next_target
        // is unaffected by the idempotent close that preceded it.
        let opener = tokio::spawn(async move {
            let open = read_raw_frame(&mut server_read).await;
            assert_eq!(open, vec![OPEN_PERSISTENT_FRAME]);
            send_frame(&mut server_write, &TunnelFrame::Open)
                .await
                .expect("open ack");
        });
        session
            .open_next_target()
            .await
            .expect("open next target after idempotent close");
        opener.await.expect("opener task");
    }

    #[tokio::test]
    async fn concurrent_send_close_calls_write_exactly_one_close_frame_and_both_await_the_ack() {
        // debt #2: `send_close`'s idempotency check used to be check-then-act,
        // not atomic under `target_open`'s lock -- two genuinely concurrent
        // Rust-level `send_close` calls could both observe `target_open ==
        // true` and both write a `Close` command. This drives the REAL
        // `send_close` (not an extracted helper) with two truly concurrent
        // callers and observes the ACTUAL frame on the wire via `recv_frame`
        // on the server side, not just the internal `target_open` flag.
        //
        // Determinism note: proving "both callers only return after the ack"
        // via a shared flag stored right after `send_frame(...).await` on
        // this task and loaded on the CALLER tasks is itself racy -- the
        // store and the loads are on different tasks with no ordering
        // relationship beyond the bytes crossing the wire, so a correct
        // implementation could still flake the assertion under adverse
        // scheduling. `JoinHandle::is_finished()`, checked from THIS task
        // in the window between receiving the frame and sending the ack,
        // has no such race: it is a direct fact about another task's
        // completion, read sequentially, not a value racing to be written.
        let (client_io, server_io) = duplex(4096);
        let (client_read, client_write) = tokio::io::split(client_io);
        let (mut server_read, mut server_write) = tokio::io::split(server_io);
        let (command_tx, command_rx) = mpsc::channel(32);
        let (frame_tx, frame_rx) = mpsc::channel(32);
        tokio::spawn(drive_guest_writer(client_write, command_rx, true));
        tokio::spawn(drive_guest_reader(client_read, frame_tx));
        let session = Arc::new(RelayStreamGuestSession {
            command_tx,
            frame_rx: TokioMutex::new(frame_rx),
            metadata: RelayStreamGuestSessionMetadata {
                mesh_ipv4: None,
                mesh_ipv6: Some("fd00::10".to_string()),
                mtu: 1280,
                session_id: "session-concurrent-close-test".to_string(),
            },
            target_open: TokioMutex::new(true),
            target_operation: TokioMutex::new(()),
            persistent: true,
        });

        let session_a = Arc::clone(&session);
        let session_b = Arc::clone(&session);
        let caller_a = tokio::spawn(async move { session_a.send_close().await });
        let caller_b = tokio::spawn(async move { session_b.send_close().await });

        // Exactly ONE Close frame must reach the wire.
        let frame = recv_frame(&mut server_read)
            .await
            .expect("recv the single Close frame");
        assert_eq!(frame, TunnelFrame::Close);

        // The deterministic core of the proof: at this precise point, BEFORE
        // the ack has been sent, neither caller may have returned yet. If
        // either had, it returned without ever having seen an ack -- exactly
        // the bug this test exists to catch.
        assert!(
            !caller_a.is_finished() && !caller_b.is_finished(),
            "a send_close call returned before the server sent its ack"
        );

        send_frame(&mut server_write, &TunnelFrame::Close)
            .await
            .expect("send the close ack");

        // Bounded: under the old check-then-act bug, a second racing
        // `send_close` could end up reading a stray extra frame off the
        // SAME `frame_rx` a well-behaved caller needed, leaving that
        // caller's drain blocked forever on an ack this test never sends a
        // second copy of. That must fail this test fast, not hang the
        // whole suite.
        tokio::time::timeout(Duration::from_secs(1), caller_a)
            .await
            .expect("first send_close call hung waiting for the ack")
            .expect("first caller task")
            .expect("first concurrent send_close");
        tokio::time::timeout(Duration::from_secs(1), caller_b)
            .await
            .expect("second send_close call hung waiting for the ack")
            .expect("second caller task")
            .expect("second concurrent send_close");

        // Proven by a bounded read seeing nothing further: no second Close
        // (or anything else) ever crossed the wire.
        let mut probe = [0u8; 1];
        let saw_more =
            tokio::time::timeout(Duration::from_millis(100), server_read.read(&mut probe)).await;
        assert!(
            saw_more.is_err(),
            "a second concurrent send_close must not write anything else"
        );
    }

    #[tokio::test]
    async fn drive_guest_writer_close_is_terminal_only_for_a_legacy_session() {
        // debt #4: `Close` used to never be terminal for the writer task
        // regardless of session kind, so a LEGACY (non-persistent) session's
        // writer lingered alive until the `RelayStreamGuestSession` Arc
        // dropped, instead of returning right after its one-and-only Close
        // like it did before persistent sessions existed. `persistent` is
        // now threaded through explicitly; this drives `drive_guest_writer`
        // directly (not through the full session API) and observes the
        // writer task's OWN lifetime, bounded by an explicit timeout rather
        // than a fixed sleep -- a slow CI box shouldn't make either branch
        // flake, and a hang must fail fast, not stall the suite.
        for persistent in [false, true] {
            let (client_io, server_io) = duplex(4096);
            let (_client_read, client_write) = tokio::io::split(client_io);
            let (mut server_read, _server_write) = tokio::io::split(server_io);
            let (command_tx, command_rx) = mpsc::channel(32);
            let mut writer = tokio::spawn(drive_guest_writer(client_write, command_rx, persistent));

            let (tx, rx) = oneshot::channel();
            command_tx
                .send(RelayStreamGuestCommand::Close(tx))
                .await
                .expect("send close command");
            let frame = recv_frame(&mut server_read)
                .await
                .expect("recv the close frame");
            assert_eq!(frame, TunnelFrame::Close);
            rx.await
                .expect("close reply channel")
                .expect("close command result");

            if persistent {
                // Must NOT terminate: proven by a short timeout over `&mut
                // writer` (polling without consuming the handle) actually
                // EXPIRING, not by absence of evidence after a fixed sleep.
                let outcome =
                    tokio::time::timeout(Duration::from_millis(200), &mut writer).await;
                assert!(
                    outcome.is_err(),
                    "drive_guest_writer must NOT terminate after Close when persistent=true, \
                     but it did: {outcome:?}"
                );
                writer.abort();
            } else {
                // Must terminate: proven by actually awaiting completion,
                // bounded so a regression back to "never terminates" fails
                // fast instead of hanging the suite.
                tokio::time::timeout(Duration::from_secs(1), writer)
                    .await
                    .expect(
                        "drive_guest_writer must terminate right after a successful Close \
                         when persistent=false, but it hung",
                    )
                    .expect("writer task");
            }
        }
    }

    #[test]
    fn ip_tunnel_session_metadata_accepts_only_route_scoped_settings() {
        let settings = NetworkSettings {
            mesh_ipv4: MeshIpv4 {
                addr: "192.0.2.2".to_string(),
                prefix_len: 24,
                peer: "192.0.2.3".to_string(),
            },
            mtu: 1280,
            session_id: "session-alpha_1".to_string(),
        };
        assert_eq!(
            validate_ip_tunnel_network_settings(settings.clone(), 1280, "session-alpha_1")
                .expect("valid settings"),
            RelayStreamGuestSessionMetadata {
                mesh_ipv4: Some(RelayStreamGuestIpv4Metadata {
                    addr: "192.0.2.2".to_string(),
                    prefix_len: 24,
                    peer: "192.0.2.3".to_string(),
                }),
                mesh_ipv6: None,
                mtu: 1280,
                session_id: "session-alpha_1".to_string(),
            }
        );

        for address in [
            "",
            "0.42.0.2",
            "192.0.2.0",
            "192.0.2.255",
            "127.0.0.1",
            "169.254.1.1",
            "224.0.0.1",
            "not-an-ip",
        ] {
            let mut candidate = settings.clone();
            candidate.mesh_ipv4.addr = address.to_string();
            assert!(
                validate_ip_tunnel_network_settings(candidate, 1280, "session-alpha_1").is_err(),
                "{address} must be rejected"
            );
        }

        for (prefix_len, peer) in [(0, "192.0.2.3"), (24, "198.51.100.3")] {
            let mut candidate = settings.clone();
            candidate.mesh_ipv4.prefix_len = prefix_len;
            candidate.mesh_ipv4.peer = peer.to_string();
            assert!(
                validate_ip_tunnel_network_settings(candidate, 1280, "session-alpha_1").is_err()
            );
        }

        for (auth_mtu, auth_session_id) in [
            (1281, "session-alpha_1"),
            (1280, "session-other"),
            (1280, ""),
        ] {
            assert!(
                validate_ip_tunnel_network_settings(settings.clone(), auth_mtu, auth_session_id)
                    .is_err()
            );
        }
    }

    #[tokio::test]
    async fn post_open_network_settings_are_consumed_before_session_metadata_returns() {
        let (mut client, mut server) = duplex(4096);
        let server_task = tokio::spawn(async move {
            send_frame(
                &mut server,
                &TunnelFrame::NetworkSettings(encode_network_settings_body(&NetworkSettings {
                    mesh_ipv4: MeshIpv4 {
                        addr: "192.0.2.2".to_string(),
                        prefix_len: 24,
                        peer: "192.0.2.3".to_string(),
                    },
                    mtu: 1280,
                    session_id: "session-alpha".to_string(),
                })),
            )
            .await
            .expect("send settings");
        });

        let metadata = receive_ip_tunnel_network_settings(
            &mut client,
            1280,
            "session-alpha",
            Duration::from_secs(1),
        )
        .await
        .expect("receive settings");
        assert_eq!(
            metadata.mesh_ipv4,
            Some(RelayStreamGuestIpv4Metadata {
                addr: "192.0.2.2".to_string(),
                prefix_len: 24,
                peer: "192.0.2.3".to_string(),
            })
        );
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn post_open_network_settings_fail_closed_when_missing_or_out_of_order() {
        let (mut missing_client, _missing_server) = duplex(4096);
        let error = receive_ip_tunnel_network_settings(
            &mut missing_client,
            1280,
            "session-alpha",
            Duration::from_millis(5),
        )
        .await
        .expect_err("missing settings must time out");
        assert!(matches!(
            error,
            RelayStreamGuestError::DataTunnel(message)
                if message == "post-open network settings timed out"
        ));

        let (mut client, mut server) = duplex(4096);
        let server_task = tokio::spawn(async move {
            send_frame(&mut server, &TunnelFrame::Data(vec![0x45]))
                .await
                .expect("send wrong frame");
        });
        let error = receive_ip_tunnel_network_settings(
            &mut client,
            1280,
            "session-alpha",
            Duration::from_secs(1),
        )
        .await
        .expect_err("out-of-order frame must fail");
        assert!(matches!(
            error,
            RelayStreamGuestError::DataTunnel(message)
                if message == "expected post-open network settings"
        ));
        server_task.await.expect("server task");
    }

    /// A settings frame is consumed EXACTLY once, during the handshake. A second
    /// one arriving mid-stream must not be mistaken for data and must not be
    /// allowed to re-point an already-configured interface: the frame decoder
    /// surfaces it as a typed error instead of a payload.
    #[tokio::test]
    async fn late_duplicate_network_settings_frame_is_refused_by_the_decoder() {
        let (mut client, mut server) = tokio::io::duplex(4096);
        let server_task = tokio::spawn(async move {
            send_frame(
                &mut server,
                &TunnelFrame::NetworkSettings(encode_network_settings_body(&NetworkSettings {
                    mesh_ipv4: MeshIpv4 {
                        addr: "192.0.2.2".to_string(),
                        prefix_len: 24,
                        peer: "192.0.2.3".to_string(),
                    },
                    mtu: 1280,
                    session_id: "session-alpha".to_string(),
                })),
            )
            .await
            .expect("send late settings");
        });

        // Real decode path, mid-stream — i.e. after the handshake already
        // consumed its one legitimate settings frame.
        let frame = recv_guest_frame(&mut client).await.expect("decode");
        let record = RelayStreamGuestFrameRecord::from(frame);
        assert_eq!(record.kind, RelayStreamGuestFrameKind::Error);
        assert_eq!(record.text, "unexpected network settings frame");
        // Fail-closed, not fail-quiet: it must not arrive as payload.
        assert_ne!(record.kind, RelayStreamGuestFrameKind::Data);
        assert!(record.data.is_empty());
        // And the refusal must not echo the address or the session id.
        assert!(!record.text.contains("192.0.2.2"));
        assert!(!record.text.contains("session-alpha"));
        server_task.await.expect("server task");
    }

    /// `FRAME_NETWORK_SETTINGS`. Declared locally, like `OPEN_PERSISTENT_FRAME`
    /// above, because the opcode is what a peer actually puts on the wire and
    /// this test has to write one the framing layer will accept.
    const NETWORK_SETTINGS_FRAME: u8 = 0x17;

    /// THE DECODE IS THE REJECTION BOUNDARY, AND IT MUST CLOSE.
    ///
    /// The settings frame carries an OPAQUE body: the framing layer wraps
    /// whatever bytes arrive without looking at them, so a peer can put
    /// arbitrary garbage inside a structurally valid frame. Nothing in
    /// `validate_ip_tunnel_network_settings` can catch that — every check there
    /// reads already-typed fields, so a body that never parsed cannot even
    /// reach them in a shape they model.
    ///
    /// This drives the real wire path (raw opcode + garbage payload, decoded by
    /// the production `recv_frame`) rather than hand-building a body, because
    /// the body type's constructor is crate-private upstream — and because the
    /// wire is where a hostile body actually comes from.
    ///
    /// The assertion is deliberately two-sided: the failure must be the DECODE
    /// error, and must NOT be any of the validator's messages. A test that only
    /// asserted "some error" would still pass if the decode were moved after
    /// validation, which is precisely the regression this guards.
    #[tokio::test]
    async fn malformed_network_settings_body_is_refused_by_the_strict_decode() {
        let (mut client, mut server) = tokio::io::duplex(4096);
        let server_task = tokio::spawn(async move {
            let mut framed = vec![NETWORK_SETTINGS_FRAME];
            framed.extend_from_slice(b"not-canonical-cbor");
            write_raw_frame(&mut server, &framed)
                .await
                .expect("send malformed settings");
        });

        let error = receive_ip_tunnel_network_settings(
            &mut client,
            1280,
            "session-alpha_1",
            Duration::from_secs(2),
        )
        .await
        .expect_err("a malformed settings body must be refused");

        let RelayStreamGuestError::DataTunnel(message) = error else {
            panic!("expected a DataTunnel error, got {error:?}");
        };
        assert!(
            message.contains("bad network_settings frame"),
            "expected the strict decoder's refusal, got {message:?}"
        );
        // Fail-closed AT THE DECODE: none of these validator messages may
        // appear, because the validator must never have been reached.
        for validator_message in [
            "post-open settings do not match authenticated session",
            "network settings address invalid",
            "network settings peer invalid",
            "network settings prefix invalid",
        ] {
            assert!(
                !message.contains(validator_message),
                "a malformed body reached the validator: {message:?}"
            );
        }
        server_task.await.expect("server task");
    }

    /// `OpenPersistent` is a frame this client SENDS. Receiving one means the
    /// peer emitted a client-role frame on the guest's read path.
    ///
    /// The dangerous mapping would be onto `Open`: the open handshake treats a
    /// bare `Open` as its ack, so translating `OpenPersistent` into `Open`
    /// would let a peer satisfy an open with a frame that is not the ack. It is
    /// surfaced as a typed error instead, and this pins that it is neither an
    /// `Open` nor silently carried as `Data`.
    #[tokio::test]
    async fn unexpected_open_persistent_frame_is_surfaced_as_an_error() {
        let (mut client, mut server) = tokio::io::duplex(4096);
        let server_task = tokio::spawn(async move {
            send_frame(&mut server, &TunnelFrame::OpenPersistent)
                .await
                .expect("send open-persistent");
        });

        let frame = recv_guest_frame(&mut client).await.expect("decode");
        let record = RelayStreamGuestFrameRecord::from(frame);
        assert_eq!(record.kind, RelayStreamGuestFrameKind::Error);
        assert_eq!(record.text, "unexpected open-persistent frame");
        assert_ne!(
            record.kind,
            RelayStreamGuestFrameKind::Open,
            "a client-role frame must never be accepted as the open ack"
        );
        assert_ne!(record.kind, RelayStreamGuestFrameKind::Data);
        assert!(record.data.is_empty());
        server_task.await.expect("server task");
    }

    // ── Consumer gate: which resource demands post-Open network settings ─────
    //
    // `relay_stream_connect` decides with a LOCAL:
    //     let requires_network_metadata = offer.payload.resource == IpTunnel;
    // There is no production seam exposing it, so the only honest way to pin it
    // is to drive the real connect path and assert its OBSERVABLE consequence.
    // Asserting the comparison itself in the test would be vacuous — it would
    // still pass with the production gate inverted.
    //
    // Reaching the gate needs a server, and the two non-Pty resources cannot use
    // credential auth (production `verify_credential_binding` requires Pty), so
    // they arrive with offer-payload material that `authorize_session` cannot
    // decode. `serve_connection_io` is generic over its verifier, so the test
    // supplies its own. That is a TEST DOUBLE for server-side authorization,
    // which is not what this test pins; production authorization is untouched.

    const GATE_PROBE_SESSION_ID: &str = "gate-probe-session";
    const GATE_PROBE_MESH_IPV6: &str = "fd00::2";

    /// Minimal session for the test verifier. Carries no real identifiers.
    struct GateProbeSession;

    impl DataTunnelSession for GateProbeSession {
        fn session_id(&self) -> String {
            GATE_PROBE_SESSION_ID.to_string()
        }
        fn mesh_ipv6(&self) -> String {
            GATE_PROBE_MESH_IPV6.to_string()
        }
    }

    /// Router that attaches a pool allocation only when the case supplies one,
    /// so the engine emits a real `NetworkSettings` frame exactly on the
    /// `IpTunnel` case and none at all otherwise.
    struct GateProbeRouter {
        vpn: Option<MeshIpv4>,
        opened: Arc<std::sync::atomic::AtomicBool>,
    }

    impl ClawTargetRouter for GateProbeRouter {
        async fn open(&self, _target_id: &str) -> Result<TargetSession, DataTunnelError> {
            self.opened.store(true, std::sync::atomic::Ordering::SeqCst);
            let (server_side, mut target_side) = duplex(4096);
            tokio::spawn(async move {
                // Silent target: drain only. The outcome must be decided by the
                // gate, never by target chatter racing the settings frame.
                let mut buf = [0u8; 256];
                while let Ok(n) = target_side.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                }
            });
            let session = TargetSession::from_stream(server_side);
            Ok(match self.vpn.clone() {
                Some(mesh_ipv4) => session.with_vpn_mesh_ipv4(mesh_ipv4),
                None => session,
            })
        }
    }

    struct GateProbeOutcome {
        metadata: RelayStreamGuestSessionMetadata,
        verifier_reached: bool,
        router_reached: bool,
    }

    /// Drive the REAL `relay_stream_connect` once, for one resource.
    ///
    /// `use_credential` selects the production auth mode: Device + credential
    /// (the only mode `verify_credential_binding` permits, and only for Pty) or
    /// credential-less offer-payload on a non-Device audience.
    async fn gate_probe_connect(
        resource: RelayStreamResource,
        use_credential: bool,
        vpn: Option<MeshIpv4>,
    ) -> GateProbeOutcome {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind listener");
        let endpoint = format!(
            "relay-stream://{}",
            listener.local_addr().expect("listener addr")
        );
        let fixture = Fixture::new_with_endpoint(endpoint);
        let offer_cbor = fixture.offer_cbor_with(|payload| {
            payload.resource = resource;
            if !use_credential {
                payload.authz = Some(RelayStreamAudience::Public);
            }
        });

        let server_offer = decode_canonical_offer(&offer_cbor).expect("decode mutated offer");
        let server_owner = fixture.owner.public();
        // Taken before `noise_keypair` moves into the task: after a partial move
        // `fixture` can no longer be borrowed whole by its `&self` methods.
        let credential_cbor = use_credential.then(|| fixture.credential_cbor());
        let owner_pub_bytes = fixture.owner.public().as_bytes().to_vec();
        let guest_pub_bytes = fixture.guest.public().as_bytes().to_vec();
        let server_noise_keypair = fixture.noise_keypair;
        let expected_hello = RendezvousHello::new(
            RendezvousRole::Guest,
            fixture.offer.payload.rendezvous_token.clone(),
        )
        .encode();

        let verifier_reached = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let router_reached = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let server_verifier = Arc::clone(&verifier_reached);
        let server_router_flag = Arc::clone(&router_reached);

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept client");
            let mut actual_hello = vec![0u8; expected_hello.len()];
            socket
                .read_exact(&mut actual_hello)
                .await
                .expect("read hello");
            let prologue = server_offer
                .to_noise_prologue_owner_verified(&server_owner, NOW)
                .expect("prologue");
            let framed = RelayStreamNoiseFramed::responder_handshake_with_prologue(
                socket,
                &prologue,
                server_noise_keypair.private_key(),
            )
            .await
            .expect("responder handshake");
            let router = GateProbeRouter {
                vpn,
                opened: server_router_flag,
            };
            // The generic-session variant: `serve_connection_io` hard-codes
            // `GuestCredential`, which the offer-payload cases cannot produce.
            let _ = serve_connection_io_with_auth_deadline(
                framed.into_async_stream(),
                NOW,
                move |_envelope: &AuthEnvelope,
                      _now: u64|
                      -> Result<GateProbeSession, DataTunnelError> {
                    server_verifier.store(true, std::sync::atomic::Ordering::SeqCst);
                    Ok(GateProbeSession)
                },
                &router,
                |_session: &GateProbeSession| false,
                Duration::from_secs(10),
            )
            .await;
        });

        let request = relay_stream_prepare_auth_signing_request(RelayStreamPrepareAuthInput {
            offer_cbor: offer_cbor.clone(),
            credential_cbor,
            expected_owner_pub: owner_pub_bytes.clone(),
            expected_guest_pub: guest_pub_bytes.clone(),
            now_unix: NOW,
            ttl_secs: 60,
            session_id: "gate-probe".to_string(),
            nonce: Some(vec![0x47; 16]),
        })
        .expect("prepare auth must succeed for a valid offer of this resource");
        let signature = fixture
            .guest
            .sign(&request.signing_bytes)
            .expect("guest sign")
            .as_bytes()
            .to_vec();

        // Bounded: a lapsed bound is an INCONCLUSIVE failure, never a pass.
        let session = tokio::time::timeout(
            Duration::from_secs(10),
            relay_stream_connect(
                offer_cbor,
                fixture.owner.public().as_bytes().to_vec(),
                fixture.guest.public().as_bytes().to_vec(),
                request,
                signature,
                NOW,
                5_000,
            ),
        )
        .await
        .expect("connect did not settle within bound — inconclusive, not a pass")
        .expect("connect must succeed for a valid offer of this resource");

        let metadata = session.metadata().await;
        server.abort();
        GateProbeOutcome {
            metadata,
            verifier_reached: verifier_reached.load(std::sync::atomic::Ordering::SeqCst),
            router_reached: router_reached.load(std::sync::atomic::Ordering::SeqCst),
        }
    }

    /// Post-Open network settings are demanded for the `IpTunnel` resource and
    /// for no other, proven through the real `relay_stream_connect` path.
    ///
    /// Each case asserts it actually reached the server verifier and the router
    /// and that the connection succeeded, so an earlier validation failure can
    /// never masquerade as the expected outcome.
    #[tokio::test]
    async fn connect_requires_network_settings_only_for_the_ip_tunnel_resource() {
        // Pty — production mode is Device + credential.
        let pty = gate_probe_connect(RelayStreamResource::Pty, true, None).await;
        assert!(pty.verifier_reached, "Pty never reached the verifier");
        assert!(pty.router_reached, "Pty never reached the router");
        assert!(
            pty.metadata.mesh_ipv4.is_none(),
            "Pty must not demand or carry an IPv4 assignment"
        );

        // ClawSite over offer-payload auth (Group/Public share). The Device
        // credential path is covered separately by
        // `prepare_accepts_clawsite_credential_offer`; both are valid ways to
        // reach a shared app.
        let clawsite = gate_probe_connect(RelayStreamResource::ClawSite, false, None).await;
        assert!(clawsite.verifier_reached, "ClawSite never reached verifier");
        assert!(clawsite.router_reached, "ClawSite never reached the router");
        assert!(
            clawsite.metadata.mesh_ipv4.is_none(),
            "ClawSite must not demand or carry an IPv4 assignment"
        );

        // IpTunnel — positive control: a real NetworkSettings frame traverses
        // the real decoder and is cross-bound to the ack.
        let ip_tunnel = gate_probe_connect(
            RelayStreamResource::IpTunnel,
            false,
            Some(MeshIpv4 {
                addr: "192.0.2.2".to_string(),
                prefix_len: 30,
                peer: "192.0.2.1".to_string(),
            }),
        )
        .await;
        assert!(
            ip_tunnel.verifier_reached,
            "IpTunnel never reached verifier"
        );
        assert!(
            ip_tunnel.router_reached,
            "IpTunnel never reached the router"
        );
        let assigned = ip_tunnel
            .metadata
            .mesh_ipv4
            .expect("IpTunnel must complete with a pool-allocated assignment");
        assert_eq!(assigned.addr, "192.0.2.2");
        assert_eq!(assigned.prefix_len, 30);
        assert_eq!(assigned.peer, "192.0.2.1");
        // Cross-bound to the authenticated session, not free-floating.
        assert_eq!(ip_tunnel.metadata.session_id, GATE_PROBE_SESSION_ID);
        assert_eq!(ip_tunnel.metadata.mtu, 1280);
    }

    /// Redaction is a property of the type, so it survives refactors: the guest
    /// address, its claw-side peer, the session id, the relay endpoint and the
    /// selected target must never reach a log through a formatter.
    #[test]
    fn debug_redacts_addresses_endpoint_target_and_session_id() {
        let ipv4 = RelayStreamGuestIpv4Metadata {
            addr: "192.0.2.2".to_string(),
            prefix_len: 24,
            peer: "192.0.2.3".to_string(),
        };
        let rendered = format!("{ipv4:?}");
        assert!(!rendered.contains("192.0.2.2"), "Debug leaked the address");
        assert!(!rendered.contains("192.0.2.3"), "Debug leaked the peer");
        assert!(rendered.contains("<redacted>"));
        // The route scope stays diagnosable.
        assert!(rendered.contains("24"));

        let metadata = RelayStreamGuestSessionMetadata {
            mesh_ipv4: Some(ipv4),
            mesh_ipv6: Some("fd00::1".to_string()),
            mtu: 1280,
            session_id: "session-alpha_1".to_string(),
        };
        let rendered = format!("{metadata:?}");
        assert!(!rendered.contains("192.0.2.2"));
        assert!(!rendered.contains("192.0.2.3"));
        assert!(!rendered.contains("fd00::1"), "Debug leaked the IPv6");
        assert!(!rendered.contains("session-alpha_1"), "Debug leaked the id");
        assert!(rendered.contains("mesh_ipv6_present: true"));
        assert!(rendered.contains("1280"));

        let request = RelayStreamAuthSigningRequest {
            auth_mode: RelayStreamAuthMode::OfferPayload,
            signing_bytes: vec![1, 2, 3],
            session_id: "session-alpha_1".to_string(),
            endpoint: "relay.example:4443".to_string(),
            target_id: "claw_secret_target".to_string(),
            expires_at: 42,
            nonce: vec![0u8; 16],
            auth_material_cbor: vec![9, 9],
            guest_device_pub: vec![7; 33],
        };
        let rendered = format!("{request:?}");
        assert!(!rendered.contains("session-alpha_1"));
        assert!(
            !rendered.contains("relay.example"),
            "Debug leaked the endpoint"
        );
        assert!(
            !rendered.contains("claw_secret_target"),
            "Debug leaked target"
        );
        assert!(rendered.contains("<redacted>"));
        // Non-identifying diagnostics survive.
        assert!(rendered.contains("expires_at: 42"));

        let input = RelayStreamPrepareAuthInput {
            offer_cbor: vec![1],
            credential_cbor: None,
            expected_owner_pub: vec![2; 33],
            expected_guest_pub: vec![3; 33],
            now_unix: 7,
            ttl_secs: 60,
            session_id: "session-alpha_1".to_string(),
            nonce: None,
        };
        let rendered = format!("{input:?}");
        assert!(!rendered.contains("session-alpha_1"));
        assert!(rendered.contains("<redacted>"));
    }

    // ─── Validator parity table ──────────────────────────────────────────────
    //
    // The route-scope rules are implemented TWICE, in two languages: here, and
    // in Swift's RelayStreamIPTunnelNetworkSettings.make. Nothing in the build
    // forces them to agree, so one physical table drives both sides. This is
    // the Rust consumer; the Swift consumer reads the SAME file.
    //
    // ASYMMETRIC ENFORCEMENT, by decision and recorded here rather than left
    // implicit. Swift pins the file's SHA-256; this side pins the exact
    // `@total`, the exact `@counts` line and the exact ordered id list of EVERY
    // category instead.
    //
    // Why not a symmetric digest: `sha2 0.10.9` is ALREADY in this crate's
    // `Cargo.lock`, transitively — `household-rs` uses it internally. It is not
    // re-exported, and this crate does not declare it, so this crate cannot
    // call it directly. Declaring it under `[dev-dependencies]` would add NO
    // new crate to the lock graph; it would only edit `Cargo.toml`, a fourth
    // path, deliberately outside this slice's scope.
    //
    // So the blocker is SCOPE AND MANIFEST, not dependency weight. Anyone
    // revisiting this should weigh it as a one-line manifest change, not as
    // pulling in a new dependency.
    //
    // Consequence, stated so nobody mistakes it for parity: a semantic row
    // change fails on BOTH sides; a whitespace-or-comment-only edit to the
    // table fails only on Swift. That residual is accepted and deliberate.

    const PARITY_TABLE: &str = "Tests/Fixtures/ip_tunnel_network_settings_validator_v1.tsv";
    const PARITY_TOTAL: &str = "33";
    const PARITY_COUNTS: &str = "both=23\trust_only=10\tswift_only=0";
    const PARITY_ORDER_BOTH: &str = "b_valid_slash30,b_valid_slash31,b_valid_slash24,b_addr_equals_peer,b_peer_outside_prefix,b_addr_is_network,b_addr_is_broadcast,b_peer_is_network,b_peer_is_broadcast,b_prefix_zero,b_prefix_32,b_addr_all_zero,b_addr_all_ones,b_addr_zero_first_octet,b_addr_loopback,b_addr_link_local,b_addr_multicast,b_peer_loopback,s_mtu_below_min,s_mtu_min,s_mtu_max,s_mtu_above_max,s_session_empty";
    const PARITY_ORDER_RUST_ONLY: &str = "r_ack_matches,r_mtu_mismatch,r_session_mismatch,r_mtu_and_session_mismatch,r_session_whitespace_only,r_session_leading_ws,r_session_trailing_ws,r_session_interior_ws,r_session_forbidden_punct,r_session_underscore_ok";
    const PARITY_ORDER_SWIFT_ONLY: &str = "";
    const PARITY_HEADER: &str = "case_id\taddr\tprefix_len\tpeer\tsettings_mtu\tsettings_session_id\tack_mtu\tack_session_id\tapplies_to\trust_expect\tswift_expect";

    /// Decode the table's explicit sentinels. Nothing here may depend on
    /// accidental trimming: `<empty>` is the empty string, `<sp>` is one space
    /// anywhere in the token, and any other `<...>` is a hard error rather than
    /// a value that quietly survives as literal text.
    fn parity_decode_session(raw: &str) -> String {
        if raw == "<empty>" {
            return String::new();
        }
        let mut out = String::new();
        let mut rest = raw;
        while let Some(start) = rest.find('<') {
            let offset = rest[start..]
                .find('>')
                .unwrap_or_else(|| panic!("unterminated sentinel in {raw:?}"));
            let end = start + offset;
            let token = &rest[start..=end];
            assert_eq!(token, "<sp>", "unknown sentinel {token} in {raw:?}");
            out.push_str(&rest[..start]);
            out.push(' ');
            rest = &rest[end + 1..];
        }
        out.push_str(rest);
        out
    }

    struct ParityRow {
        case_id: String,
        addr: String,
        prefix_len: u8,
        peer: String,
        settings_mtu: u16,
        settings_session_id: String,
        ack_mtu: u16,
        ack_session_id: String,
        applies_to: String,
        rust_expect: String,
    }

    /// Strict, fail-closed parse. Every line must be a recognised kind, every
    /// data row must have exactly 11 columns, every enum-valued column must be
    /// a known value, and the verdict column for a side the row does not apply
    /// to must be exactly `n/a`. Nothing is skipped silently.
    fn parity_rows() -> Vec<ParityRow> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(PARITY_TABLE);
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("parity table unreadable at {}: {e}", path.display()));

        let mut saw_total = false;
        let mut saw_counts = false;
        let mut saw_header = false;
        let mut orders: Vec<(String, String)> = Vec::new();
        let mut rows: Vec<ParityRow> = Vec::new();

        for line in text.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(rest) = line.strip_prefix("@total\t") {
                assert_eq!(rest, PARITY_TOTAL, "declared @total changed");
                saw_total = true;
                continue;
            }
            if let Some(rest) = line.strip_prefix("@counts\t") {
                assert_eq!(rest, PARITY_COUNTS, "declared @counts line changed");
                saw_counts = true;
                continue;
            }
            if let Some(rest) = line.strip_prefix("@order\t") {
                let (category, ids) = rest.split_once('\t').unwrap_or((rest, ""));
                orders.push((category.to_string(), ids.to_string()));
                continue;
            }
            if line == PARITY_HEADER {
                saw_header = true;
                continue;
            }
            assert!(saw_header, "data row before the header: {line}");

            let cols: Vec<&str> = line.split('\t').collect();
            assert_eq!(cols.len(), 11, "row must have 11 columns: {line}");
            let applies_to = cols[8];
            assert!(
                matches!(applies_to, "both" | "rust_only" | "swift_only"),
                "unknown applies_to {applies_to}"
            );
            for verdict in [cols[9], cols[10]] {
                assert!(
                    matches!(verdict, "accept" | "reject" | "n/a"),
                    "unknown verdict {verdict}"
                );
            }
            match applies_to {
                "both" => {
                    assert_ne!(cols[9], "n/a", "both row lacks a rust verdict: {line}");
                    assert_ne!(cols[10], "n/a", "both row lacks a swift verdict: {line}");
                }
                "rust_only" => assert_eq!(cols[10], "n/a", "rust_only row must not verdict swift"),
                _ => assert_eq!(cols[9], "n/a", "swift_only row must not verdict rust"),
            }

            rows.push(ParityRow {
                case_id: cols[0].to_string(),
                addr: cols[1].to_string(),
                prefix_len: cols[2].parse().expect("prefix_len"),
                peer: cols[3].to_string(),
                settings_mtu: cols[4].parse().expect("settings_mtu"),
                settings_session_id: parity_decode_session(cols[5]),
                ack_mtu: cols[6].parse().expect("ack_mtu"),
                ack_session_id: parity_decode_session(cols[7]),
                applies_to: applies_to.to_string(),
                rust_expect: cols[9].to_string(),
            });
        }

        assert!(saw_total && saw_counts && saw_header, "table lost a directive");
        // Every category is declared, INCLUDING the empty one: an omitted
        // `swift_only` would otherwise read as "no Swift-only rules" when it
        // actually means the category vanished.
        let expected_orders = [
            ("both", PARITY_ORDER_BOTH),
            ("rust_only", PARITY_ORDER_RUST_ONLY),
            ("swift_only", PARITY_ORDER_SWIFT_ONLY),
        ];
        assert_eq!(orders.len(), 3, "expected exactly three @order directives");
        for (index, (category, ids)) in expected_orders.iter().enumerate() {
            assert_eq!(&orders[index].0, category, "@order category or order changed");
            assert_eq!(&orders[index].1, ids, "@order id list for {category} changed");
        }

        assert_eq!(rows.len(), 33, "table row count changed");
        let ids: std::collections::BTreeSet<&str> =
            rows.iter().map(|r| r.case_id.as_str()).collect();
        assert_eq!(ids.len(), rows.len(), "duplicate case_id in the table");
        rows
    }

    /// Execute every row this side owns — `both` and `rust_only` — and assert
    /// the ordered ids consumed match the declaration exactly, so a row cannot
    /// be skipped without failing.
    #[test]
    fn validator_parity_table_matches_the_rust_validator() {
        let rows = parity_rows();

        let mut consumed_both: Vec<&str> = Vec::new();
        let mut consumed_rust: Vec<&str> = Vec::new();

        for row in &rows {
            match row.applies_to.as_str() {
                "both" => consumed_both.push(&row.case_id),
                "rust_only" => consumed_rust.push(&row.case_id),
                _ => continue,
            }

            let settings = NetworkSettings {
                mesh_ipv4: MeshIpv4 {
                    addr: row.addr.clone(),
                    prefix_len: row.prefix_len,
                    peer: row.peer.clone(),
                },
                mtu: row.settings_mtu,
                session_id: row.settings_session_id.clone(),
            };
            let outcome = validate_ip_tunnel_network_settings(
                settings,
                row.ack_mtu,
                &row.ack_session_id,
            );
            let expected_accept = row.rust_expect == "accept";
            assert_eq!(
                outcome.is_ok(),
                expected_accept,
                "row {} expected {} from the Rust validator, got {outcome:?}",
                row.case_id,
                row.rust_expect
            );
        }

        assert_eq!(
            consumed_both.join(","),
            PARITY_ORDER_BOTH,
            "the `both` rows consumed do not match the declaration"
        );
        assert_eq!(
            consumed_rust.join(","),
            PARITY_ORDER_RUST_ONLY,
            "the `rust_only` rows consumed do not match the declaration"
        );
    }
}
