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
use std::sync::{Arc, Mutex};
use std::time::Duration;

use household_rs::KeystoreError;
use household_rs::cbor;
use household_rs::claw_share::GuestCredential;
use household_rs::claw_share_data_tunnel::{
    AuthEnvelope, DataTunnelError, HEALTH_PROBE, SessionAuthToken, TargetExit, TunnelAck,
    TunnelFrame, client_authenticate, client_health, client_open_stream, client_resize, recv_frame,
    send_frame,
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
            .field("session_id", &self.session_id)
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
            .field("session_id", &self.session_id)
            .field("endpoint", &self.endpoint)
            .field("target_id", &self.target_id)
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
}

enum RelayStreamGuestCommand {
    Data(Vec<u8>, oneshot::Sender<Result<(), RelayStreamGuestError>>),
    Resize(u16, u16, oneshot::Sender<Result<(), RelayStreamGuestError>>),
    Close(oneshot::Sender<Result<(), RelayStreamGuestError>>),
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
    let stream = connect_relay_stream_tcp(
        &offer_cbor,
        &expected_owner_pub,
        &expected_guest_pub,
        now_unix,
        Duration::from_millis(connect_timeout_ms),
    )
    .await?;
    let stream = authenticate_health_open(stream, &request, &signature).await?;
    let (read_half, write_half) = tokio::io::split(stream);
    let (command_tx, command_rx) = mpsc::channel(32);
    let (frame_tx, frame_rx) = mpsc::channel(32);
    tokio::spawn(drive_guest_writer(write_half, command_rx));
    tokio::spawn(drive_guest_reader(read_half, frame_tx));
    Ok(Arc::new(RelayStreamGuestSession {
        command_tx,
        frame_rx: TokioMutex::new(frame_rx),
    }))
}

#[uniffi::export(async_runtime = "tokio")]
impl RelayStreamGuestSession {
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

    pub async fn send_close(&self) -> Result<(), RelayStreamGuestError> {
        let (tx, rx) = oneshot::channel();
        self.command_tx
            .send(RelayStreamGuestCommand::Close(tx))
            .await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?;
        rx.await
            .map_err(|_| RelayStreamGuestError::Io("relay stream session closed".to_string()))?
    }

    pub async fn read_frame(&self) -> Result<RelayStreamGuestFrameRecord, RelayStreamGuestError> {
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
) where
    W: AsyncWrite + Unpin,
{
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
                let result = send_close(&mut stream).await;
                let _ = reply.send(result);
                return;
            }
        };
        if should_stop {
            return;
        }
    }
    let _ = send_close(&mut stream).await;
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
    mut stream: S,
    request: &RelayStreamAuthSigningRequest,
    signature: &[u8],
) -> Result<S, RelayStreamGuestError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let token = signed_session_auth_token(request, signature)?;
    match client_authenticate(&mut stream, &request.auth_material_cbor, token).await? {
        TunnelAck::Ok { .. } => {}
        TunnelAck::Rejected { reason } => return Err(RelayStreamGuestError::AuthRejected(reason)),
    }
    let echo = client_health(&mut stream, HEALTH_PROBE).await?;
    if echo != HEALTH_PROBE {
        return Err(RelayStreamGuestError::HealthMismatch);
    }
    client_open_stream(&mut stream).await?;
    Ok(stream)
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
    if offer.payload.resource != RelayStreamResource::Pty {
        return Err(RelayStreamGuestError::Credential(
            "credential auth requires pty resource".to_string(),
        ));
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
        ClawTargetRouter, ReplayGuard, TargetSession, authorize_session, serve_connection_io,
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
            (
                fixture.offer_cbor_with(|payload| {
                    payload.resource = RelayStreamResource::ClawSite;
                }),
                "credential auth requires pty resource",
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
        tokio::spawn(drive_guest_writer(client_write, command_rx));
        tokio::spawn(drive_guest_reader(client_read, frame_tx));
        let session = Arc::new(RelayStreamGuestSession {
            command_tx,
            frame_rx: TokioMutex::new(frame_rx),
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
}
