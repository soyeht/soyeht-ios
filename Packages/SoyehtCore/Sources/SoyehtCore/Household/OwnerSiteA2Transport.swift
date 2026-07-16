import Foundation

/// Shared vocabulary for the frozen A2-R1 record profile.
///
/// The record transport is intentionally not wired to any WebSocket, peer,
/// dial, proxy, or site-byte effect. Those boundaries remain separately
/// reviewed even when the local cryptographic state machine is introduced.
enum OwnerSiteA2TransportProfile {
    static let domain = "soyeht/owner-site/a2/v1"
    static let version: UInt64 = 1
    static let recordVersion = "a2-record-v1"
    static let protocolName = "Noise_XXa2v1_25519_ChaChaPoly_SHA256"
    static let frozenCorpusSHA256 =
        "dde67030a035928d0a859a19fc7dcf14ea8e8fa54643e9f66302652740548330"

    static let maximumCiphertextBytes = 16_384
    static let maximumPlaintextBytes = 16_368
    static let maximumEnvelopeBytes = 16_389
    static let authenticationTagBytes = 16
}

/// Fixed, on-wire directional values.
enum OwnerSiteA2RecordDirection: UInt64, Sendable {
    case deviceToEngine = 0
    case engineToDevice = 1
}

/// Fixed, encrypted record kinds from the A2-R1 contract.
enum OwnerSiteA2RecordKind: UInt64, Sendable {
    case serverFinished = 1
    case clientFinishedAck = 2
    case sitePayload = 3
    case close = 4
}
