import Foundation

/// Ephemeral host-to-extension handoff for a prepared relay-stream session.
///
/// This value is passed only through `startVPNTunnel(options:)`. It must never
/// be written to `providerConfiguration`, UserDefaults, an App Group, or disk.
/// The host performs the Secure Enclave signature; the packet-tunnel extension
/// receives no private signing capability.
public struct RelayStreamGuestTunnelStartOptions: Codable, Sendable, Equatable {
    public static let optionKey = "soyeht.relay-stream.ip-tunnel.start-options"
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let offerCbor: Data
    public let expectedOwnerPub: Data
    public let expectedGuestPub: Data
    public let authMode: RelayStreamGuestAuthModeWire
    public let signingBytes: Data
    public let sessionId: String
    public let endpoint: String
    public let targetId: String
    public let expiresAt: UInt64
    public let nonce: Data
    public let authMaterialCbor: Data
    public let guestDevicePub: Data
    public let signature: Data
    public let issuedAtUnix: UInt64
    public let connectTimeoutMs: UInt64

    public init(
        offerCbor: Data,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        request: RelayStreamAuthSigningRequest,
        signature: Data,
        issuedAtUnix: UInt64,
        connectTimeoutMs: UInt64
    ) throws {
        self.version = Self.currentVersion
        self.offerCbor = offerCbor
        self.expectedOwnerPub = expectedOwnerPub
        self.expectedGuestPub = expectedGuestPub
        self.authMode = try RelayStreamGuestAuthModeWire(request.authMode)
        self.signingBytes = request.signingBytes
        self.sessionId = request.sessionId
        self.endpoint = request.endpoint
        self.targetId = request.targetId
        self.expiresAt = request.expiresAt
        self.nonce = request.nonce
        self.authMaterialCbor = request.authMaterialCbor
        self.guestDevicePub = request.guestDevicePub
        self.signature = signature
        self.issuedAtUnix = issuedAtUnix
        self.connectTimeoutMs = connectTimeoutMs
        try validate(nowUnix: issuedAtUnix)
    }

    public func encode() throws -> Data {
        try validate(nowUnix: issuedAtUnix)
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data, nowUnix: UInt64) throws -> Self {
        guard data.count <= Limits.maximumEncodedBytes else {
            throw RelayStreamGuestTunnelStartOptionsError.oversized
        }
        let decoded: Self
        do {
            decoded = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw RelayStreamGuestTunnelStartOptionsError.malformed
        }
        try decoded.validate(nowUnix: nowUnix)
        return decoded
    }

    public func authSigningRequest() throws -> RelayStreamAuthSigningRequest {
        try validate(nowUnix: issuedAtUnix)
        return RelayStreamAuthSigningRequest(
            authMode: authMode.native,
            signingBytes: signingBytes,
            sessionId: sessionId,
            endpoint: endpoint,
            targetId: targetId,
            expiresAt: expiresAt,
            nonce: nonce,
            authMaterialCbor: authMaterialCbor,
            guestDevicePub: guestDevicePub
        )
    }

    public func validate(nowUnix: UInt64) throws {
        guard version == Self.currentVersion else {
            throw RelayStreamGuestTunnelStartOptionsError.unsupportedVersion
        }
        guard !offerCbor.isEmpty,
              offerCbor.count <= Limits.maximumOfferBytes,
              expectedOwnerPub.count == 33,
              expectedGuestPub.count == 33,
              expectedGuestPub == guestDevicePub,
              !signingBytes.isEmpty,
              signingBytes.count <= Limits.maximumSigningBytes,
              !sessionId.isEmpty,
              sessionId.utf8.count <= Limits.maximumIdentifierBytes,
              !endpoint.isEmpty,
              endpoint.utf8.count <= Limits.maximumEndpointBytes,
              !targetId.isEmpty,
              targetId.utf8.count <= Limits.maximumIdentifierBytes,
              nonce.count >= 16,
              nonce.count <= 128,
              !authMaterialCbor.isEmpty,
              authMaterialCbor.count <= Limits.maximumOfferBytes,
              !signature.isEmpty,
              signature.count <= 144,
              connectTimeoutMs > 0,
              connectTimeoutMs <= Limits.maximumConnectTimeoutMs
        else {
            throw RelayStreamGuestTunnelStartOptionsError.malformed
        }
        let (latestAllowedIssueTime, clockSkewOverflow) =
            nowUnix.addingReportingOverflow(Limits.maximumClockSkewSeconds)
        guard !clockSkewOverflow,
              issuedAtUnix <= latestAllowedIssueTime,
              nowUnix < expiresAt,
              expiresAt - nowUnix <= Limits.maximumRemainingLifetimeSeconds
        else {
            throw RelayStreamGuestTunnelStartOptionsError.expired
        }
    }

    private enum Limits {
        static let maximumEncodedBytes = 512 * 1_024
        static let maximumOfferBytes = 128 * 1_024
        static let maximumSigningBytes = 128 * 1_024
        static let maximumIdentifierBytes = 512
        static let maximumEndpointBytes = 2_048
        static let maximumConnectTimeoutMs: UInt64 = 60_000
        static let maximumClockSkewSeconds: UInt64 = 30
        static let maximumRemainingLifetimeSeconds: UInt64 = 5 * 60
    }
}

public enum RelayStreamGuestAuthModeWire: String, Codable, Sendable, Equatable {
    case deviceCredential = "device_credential"
    case offerPayload = "offer_payload"

    init(_ native: RelayStreamAuthMode) throws {
        switch native {
        case .deviceCredential:
            self = .deviceCredential
        case .offerPayload:
            self = .offerPayload
        }
    }

    var native: RelayStreamAuthMode {
        switch self {
        case .deviceCredential:
            return .deviceCredential
        case .offerPayload:
            return .offerPayload
        }
    }
}

public enum RelayStreamGuestTunnelStartOptionsError: Error, Sendable, Equatable {
    case malformed
    case oversized
    case unsupportedVersion
    case expired
}
