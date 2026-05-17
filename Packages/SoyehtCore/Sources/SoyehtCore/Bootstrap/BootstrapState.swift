import Foundation

/// Bootstrap lifecycle state — mirrors theyos engine enum exactly.
/// Raw values MUST match the "state" field in `GET /bootstrap/status`.
public enum BootstrapState: String, Sendable, Equatable {
    case uninitialized = "uninitialized"
    case readyForNaming = "ready_for_naming"
    case namedAwaitingPair = "named_awaiting_pair"
    case ready = "ready"
    /// Stub only this delivery; engine emits the value but never transitions into it.
    case recovering = "recovering"
}

// MARK: - BootstrapStatusResponse

/// Decoded response from `GET /bootstrap/status`.
public struct BootstrapStatusResponse: Equatable, Sendable {
    public let version: UInt64
    public let state: BootstrapState
    public let engineVersion: String
    public let platform: String
    /// `Host.localizedName`; empty string for Linux v1 engines.
    public let hostLabel: String
    /// `nil` when state is `uninitialized` or `ready_for_naming`.
    public let ownerDisplayName: String?
    public let deviceCount: UInt8
    /// `nil` until `POST /bootstrap/initialize` succeeds.
    public let hhId: String?
    /// 33-byte SEC1 compressed P-256. `nil` until `POST /bootstrap/initialize` succeeds.
    public let hhPub: Data?

    public init(
        version: UInt64,
        state: BootstrapState,
        engineVersion: String,
        platform: String,
        hostLabel: String,
        ownerDisplayName: String?,
        deviceCount: UInt8,
        hhId: String?,
        hhPub: Data?
    ) {
        self.version = version
        self.state = state
        self.engineVersion = engineVersion
        self.platform = platform
        self.hostLabel = hostLabel
        self.ownerDisplayName = ownerDisplayName
        self.deviceCount = deviceCount
        self.hhId = hhId
        self.hhPub = hhPub
    }
}

// MARK: - BootstrapInitializeResponse

/// Decoded response from `POST /bootstrap/initialize`.
public struct BootstrapInitializeResponse: Equatable, Sendable {
    public let version: UInt64
    public let hhId: String
    /// 33-byte SEC1 compressed P-256.
    public let hhPub: Data
    /// `soyeht://pair-device?...` format.
    public let pairQrUri: String

    public init(version: UInt64, hhId: String, hhPub: Data, pairQrUri: String) {
        self.version = version
        self.hhId = hhId
        self.hhPub = hhPub
        self.pairQrUri = pairQrUri
    }
}

// MARK: - BootstrapPairDeviceURIResponse

/// Decoded response from `GET /bootstrap/pair-device-uri`.
///
/// The endpoint is only valid while the engine is `named_awaiting_pair`; it
/// returns the same first-owner pairing URI the Mac can render as QR, but lets
/// trusted setup-discovery flows hand it to the iPhone without making QR the
/// primary path.
public struct BootstrapPairDeviceURIResponse: Equatable, Sendable {
    public let version: UInt64
    public let houseName: String
    public let hostLabel: String
    public let hhId: String
    /// 33-byte SEC1 compressed P-256.
    public let hhPub: Data
    public let pairDeviceURI: String
    public let expiresAt: UInt64?

    public init(
        version: UInt64,
        houseName: String,
        hostLabel: String,
        hhId: String,
        hhPub: Data,
        pairDeviceURI: String,
        expiresAt: UInt64?
    ) {
        self.version = version
        self.houseName = houseName
        self.hostLabel = hostLabel
        self.hhId = hhId
        self.hhPub = hhPub
        self.pairDeviceURI = pairDeviceURI
        self.expiresAt = expiresAt
    }
}

// MARK: - BootstrapError

/// Typed errors from `/bootstrap/*` endpoints.
public enum BootstrapError: Error, Equatable, Sendable {
    /// Transport-layer failure (no DNS, no route, TLS broken, socket reset).
    case networkDrop
    /// Server sent a well-formed CBOR error envelope with a typed `code`.
    case serverError(code: String, message: String?)
    /// Response violated the wire contract.
    case protocolViolation(detail: BootstrapProtocolViolationDetail)
}

extension BootstrapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .networkDrop:
            return "Soyeht is not responding on this Mac."
        case .serverError(let code, let message):
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            return Self.defaultServerErrorDescription(for: code)
        case .protocolViolation(let detail):
            return detail.errorDescription
        }
    }

    private static func defaultServerErrorDescription(for code: String) -> String {
        switch code {
        case "already_initialized":
            return "Soyeht is already set up on this Mac."
        case "engine_initializing":
            return "Soyeht is still starting. Try again in a moment."
        case "tailnet_required":
            return "Turn on Tailscale to add machines to this home."
        default:
            return "Soyeht returned an error: \(code)."
        }
    }
}

public enum BootstrapProtocolViolationDetail: Equatable, Sendable {
    case wrongContentType(returned: String?)
    case malformedErrorBody
    case unexpectedResponseShape
    case unsupportedEnvelopeVersion(UInt64)
    case missingRequiredField
    case unknownStateValue(String)
}

extension BootstrapProtocolViolationDetail {
    var errorDescription: String {
        switch self {
        case .wrongContentType:
            return "Soyeht returned an unexpected response type."
        case .malformedErrorBody:
            return "Soyeht returned an unreadable error response."
        case .unexpectedResponseShape:
            return "Soyeht returned an unexpected response."
        case .unsupportedEnvelopeVersion(let version):
            return "Soyeht returned an unsupported response version: \(version)."
        case .missingRequiredField:
            return "Soyeht returned an incomplete response."
        case .unknownStateValue(let state):
            return "Soyeht returned an unknown setup state: \(state)."
        }
    }
}
