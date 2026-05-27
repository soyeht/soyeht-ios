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

    /// Top-level phase of the macOS guest-image init. Snake-case value
    /// from `init-state.json::phase` — one of `download_ipsw`,
    /// `create_disk`, `install_macos`, `provision`, `create_snapshot`,
    /// `complete`. Added by theyos v0.1.19. `nil` on Linux engines (no
    /// guest VM concept) and on Macs that haven't started provisioning
    /// yet (`init-state.json` missing). Pre-v0.1.19 engines also omit
    /// the field entirely; the decoder treats absence as `nil`.
    public let guestImagePhase: String?

    /// Overall status of the macOS guest-image init. Snake-case value
    /// from `init-state.json::status` — one of `pending`, `in_progress`,
    /// `done`, `failed`. Added by theyos v0.1.19. Same nil semantics as
    /// `guestImagePhase`. Disambiguate Linux-nil from Mac-nil via the
    /// `platform` field on this response — see `guestImageReadiness`
    /// for the canonical mapping.
    public let guestImageStatus: String?

    /// Most recent error message from a failed phase attempt. Populated
    /// only when `guestImageStatus == "failed"`. Surfaced verbatim in
    /// the iOS UI as a recovery hint. Added by theyos v0.1.19.
    public let guestImageError: String?

    public init(
        version: UInt64,
        state: BootstrapState,
        engineVersion: String,
        platform: String,
        hostLabel: String,
        ownerDisplayName: String?,
        deviceCount: UInt8,
        hhId: String?,
        hhPub: Data?,
        guestImagePhase: String? = nil,
        guestImageStatus: String? = nil,
        guestImageError: String? = nil
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
        self.guestImagePhase = guestImagePhase
        self.guestImageStatus = guestImageStatus
        self.guestImageError = guestImageError
    }
}

// MARK: - GuestImageReadiness

/// Disambiguated state of the macOS guest-image base, derived from the
/// raw `guest_image_*` fields on `BootstrapStatusResponse`. Linux nil and
/// Mac nil are NOT the same thing — Linux engines have no guest VM
/// concept and install is always allowed; Mac engines with nil fields
/// haven't started provisioning yet and install must be gated until
/// `init-state.json` reports `done`. The mapping consults `platform` so
/// the call sites don't have to.
public enum GuestImageReadiness: Equatable, Sendable {
    /// Engine is Linux — guest VM doesn't apply. Install allowed.
    case notApplicable

    /// Engine is macOS but `init-state.json` is absent (`guest_image_*`
    /// fields all nil). User must run guest-image preparation on the
    /// Mac before Claw install can target this host. Install gated.
    case notStarted

    /// Engine is macOS and the guest-image init is running. The
    /// associated value is the phase string (`download_ipsw`,
    /// `create_disk`, `install_macos`, `provision`, `create_snapshot`)
    /// for UI labeling. Install gated.
    ///
    /// `pending` (phase about to start) and `in_progress` (phase
    /// running) both map here — both gate install equally.
    case inProgress(phase: String)

    /// Engine is macOS and the guest-image init completed
    /// successfully. Install allowed.
    case ready

    /// Engine is macOS and the most recent init attempt failed. The
    /// associated value carries the engine's error message verbatim
    /// when populated. Install gated; recovery happens on the Mac.
    case failed(error: String?)

    /// Single-shot predicate consumed by the iOS Claw Detail / picker
    /// gate. True only when the readiness state allows install:
    ///
    ///   - Linux engines (`.notApplicable`) — no guest VM, always OK.
    ///   - Mac engines with `init-state.json` reporting `done`
    ///     (`.ready`).
    ///
    /// All other states gate install, including `.notStarted`,
    /// `.inProgress`, and `.failed`.
    public var allowsInstall: Bool {
        switch self {
        case .notApplicable, .ready: return true
        case .notStarted, .inProgress, .failed: return false
        }
    }
}

public extension BootstrapStatusResponse {
    /// Canonical mapping from the raw `guest_image_*` fields to the
    /// structured `GuestImageReadiness` state. Platform-aware so Linux
    /// nil and Mac nil are distinguished — see `GuestImageReadiness`
    /// doc for the invariants.
    ///
    /// Unknown future status strings on macOS engines are conservatively
    /// mapped to `.inProgress(phase: ...)` so install is gated until a
    /// client update teaches the decoder about the new value. The phase
    /// associated value falls through to the status string when no
    /// phase is reported, so the UI always has something non-empty to
    /// render.
    var guestImageReadiness: GuestImageReadiness {
        // Platform discrimination is the load-bearing invariant: Linux
        // engines never populate guest_image_* fields, so nil there is
        // "no guest concept", not "needs prep". Macs share the same
        // nil shape pre-prep, so we must NOT collapse them.
        let isMac = platform.lowercased() == "macos"
        guard isMac else { return .notApplicable }

        switch guestImageStatus {
        case "done":
            return .ready
        case "failed":
            return .failed(error: guestImageError)
        case "in_progress", "pending":
            // The phase string is the UI's source of truth for "which
            // step is running". Fall back to the status string when
            // phase is absent so the UI is never empty.
            return .inProgress(phase: guestImagePhase ?? guestImageStatus ?? "unknown")
        case nil:
            // Mac engine with no init-state.json — provisioning hasn't
            // started yet. Distinct from Linux nil (`.notApplicable`).
            return .notStarted
        default:
            // Unknown future value from a newer engine. Be conservative:
            // gate install until the iOS client is taught to handle it.
            return .inProgress(phase: guestImagePhase ?? guestImageStatus ?? "unknown")
        }
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
    /// Engine is too old for this iOS client. Engine answered correctly,
    /// but its semver is below `EngineCompat.minSupportedEngineVersion`.
    /// Raised by the pre-flight handshake before any mutating POST.
    case engineTooOld(found: String, required: String)
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
        case .engineTooOld(let found, let required):
            return "This Mac is running an older Soyeht engine (\(found)). "
                 + "Update Soyeht on it to \(required) or newer first."
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
