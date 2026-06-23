import Foundation

// MARK: - Typed install status / phase
//
// InstallStatus mirrors `install.status` in the backend ClawAvailability
// projection. Unknown string values fall through to `.unknown` so a future
// backend value does not hard-crash the decoder, but ClawInstallState treats
// `.unknown` as terminal (fail-fast contract-drift defense — adding a new
// value in the backend MUST be mirrored here, not absorbed transitorily).

public enum InstallStatus: String, Codable, Hashable, Sendable {
    case notInstalled = "not_installed"
    case installing
    case succeeded
    case failed
    case uninstalling
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InstallStatus(rawValue: raw) ?? .unknown
    }
}

public enum InstallPhase: String, Codable, Hashable, Sendable {
    case downloading
    case verifying
    case finalizing
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InstallPhase(rawValue: raw) ?? .unknown
    }
}

// MARK: - Claw Availability Projection
//
// Single source of truth for dynamic claw state. Mirrors core_rs::availability.
// Tagged enums (OverallState, Degradation) use manual Codable because JSON
// discriminators are `state` / `type`. `UnavailReason` is already defined at
// module level in SoyehtCore/API/UnavailReason.swift — reused here.

public struct ClawAvailability: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let install: InstallProjection
    public let host: HostProjection
    public let overall: OverallState
    public let reasons: [UnavailReason]
    public let degradations: [Degradation]

    public init(
        name: String,
        install: InstallProjection,
        host: HostProjection,
        overall: OverallState,
        reasons: [UnavailReason],
        degradations: [Degradation]
    ) {
        self.name = name
        self.install = install
        self.host = host
        self.overall = overall
        self.reasons = reasons
        self.degradations = degradations
    }
}

public struct InstallProjection: Codable, Equatable, Hashable, Sendable {
    public let status: InstallStatus
    public let progress: InstallProgress?
    public let installedAt: String?
    public let error: String?
    public let jobId: String?

    public init(status: InstallStatus, progress: InstallProgress?, installedAt: String?, error: String?, jobId: String?) {
        self.status = status
        self.progress = progress
        self.installedAt = installedAt
        self.error = error
        self.jobId = jobId
    }
}

public struct InstallProgress: Codable, Equatable, Hashable, Sendable {
    public let phase: InstallPhase
    public let percent: Int
    public let bytesDownloaded: Int
    public let bytesTotal: Int
    public let updatedAtMs: Int

    public init(phase: InstallPhase, percent: Int, bytesDownloaded: Int, bytesTotal: Int, updatedAtMs: Int) {
        self.phase = phase
        self.percent = percent
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
        self.updatedAtMs = updatedAtMs
    }

    public var fraction: Double { max(0, min(1, Double(percent) / 100.0)) }
    public var downloadedMB: Int { bytesDownloaded / 1_000_000 }
    public var totalMB: Int { bytesTotal / 1_000_000 }
    public var hasBytes: Bool { bytesTotal > 0 }
}

public struct HostProjection: Codable, Equatable, Hashable, Sendable {
    public let coldPathReady: Bool
    public let hasGolden: Bool
    public let hasBaseRootfs: Bool
    public let maintenanceBlocked: Bool
    public let maintenanceRetryAfterSecs: Int?

    public init(coldPathReady: Bool, hasGolden: Bool, hasBaseRootfs: Bool, maintenanceBlocked: Bool, maintenanceRetryAfterSecs: Int?) {
        self.coldPathReady = coldPathReady
        self.hasGolden = hasGolden
        self.hasBaseRootfs = hasBaseRootfs
        self.maintenanceBlocked = maintenanceBlocked
        self.maintenanceRetryAfterSecs = maintenanceRetryAfterSecs
    }
}

// Tagged enum with discriminator `state`. Manual Codable.
public enum OverallState: Codable, Equatable, Hashable, Sendable {
    case creatable
    case installing(percent: Int)
    case notInstalled
    case failed(error: String)
    case blocked
    case unknown

    private enum CodingKeys: String, CodingKey { case state, percent, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .state)
        switch tag {
        case "creatable":     self = .creatable
        case "installing":    self = .installing(percent: try c.decodeIfPresent(Int.self, forKey: .percent) ?? 0)
        case "not_installed": self = .notInstalled
        case "failed":        self = .failed(error: try c.decodeIfPresent(String.self, forKey: .error) ?? "unknown")
        case "blocked":       self = .blocked
        default:              self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .creatable:         try c.encode("creatable",     forKey: .state)
        case .installing(let p): try c.encode("installing",    forKey: .state); try c.encode(p, forKey: .percent)
        case .notInstalled:      try c.encode("not_installed", forKey: .state)
        case .failed(let e):     try c.encode("failed",        forKey: .state); try c.encode(e, forKey: .error)
        case .blocked:           try c.encode("blocked",       forKey: .state)
        case .unknown:           try c.encode("unknown",       forKey: .state)
        }
    }
}

public enum Degradation: Codable, Equatable, Hashable, Sendable {
    case baseRootfsMissingButGoldenPresent
    case unknown(String)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "base_rootfs_missing_but_golden_present":
            self = .baseRootfsMissingButGoldenPresent
        default:
            self = .unknown(tag)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .baseRootfsMissingButGoldenPresent:
            try c.encode("base_rootfs_missing_but_golden_present", forKey: .type)
        case .unknown(let s):
            try c.encode(s, forKey: .type)
        }
    }
}

// MARK: - ClawInstallState — single source of UI truth
//
// Two orthogonal axes embedded in one enum for exhaustive switching:
//   - install axis: notInstalled / installing / uninstalling / installed /
//     installedButBlocked / installFailed
//   - create axis: whether the user can create an instance (canCreate)

public enum ClawInstallState: Equatable, Sendable {
    case notInstalled
    case installing(InstallProgress?)
    case uninstalling
    case installed
    case installedButBlocked(reasons: [UnavailReason])
    case installFailed(error: String)
    case unknown

    public init(_ availability: ClawAvailability) {
        // FAIL-FAST: drift on EITHER axis becomes .unknown. This check must
        // come BEFORE the main switch to prevent cases like
        //   install.status == .succeeded + overall == .unknown
        // from silently resolving to .installedButBlocked.
        if availability.install.status == .unknown { self = .unknown; return }
        if case .unknown = availability.overall    { self = .unknown; return }

        switch availability.install.status {
        case .installing:
            self = .installing(availability.install.progress)

        case .uninstalling:
            self = .uninstalling

        case .failed:
            let installErr = availability.install.error
            let overallErr: String? = {
                if case .failed(let e) = availability.overall { return e }
                return nil
            }()
            self = .installFailed(error: installErr ?? overallErr ?? "unknown")

        case .succeeded:
            if case .creatable = availability.overall {
                self = .installed
            } else {
                self = .installedButBlocked(reasons: availability.reasons)
            }

        case .notInstalled:
            self = .notInstalled

        case .unknown:
            self = .unknown
        }
    }

    public var isInstalling: Bool {
        if case .installing = self { return true } else { return false }
    }

    public var isUninstalling: Bool {
        if case .uninstalling = self { return true } else { return false }
    }

    public var isInstalled: Bool {
        switch self {
        case .installed, .installedButBlocked, .uninstalling: return true
        default: return false
        }
    }

    public var canCreate: Bool {
        if case .installed = self { return true } else { return false }
    }

    public var canUninstall: Bool {
        switch self {
        case .installed, .installedButBlocked: return true
        default: return false
        }
    }

    public var isTransient: Bool { isInstalling || isUninstalling }
    public var isTerminal: Bool { !isTransient }
}

// MARK: - Claw Installability (static catalog gate)
//
// Distinct from `ClawInstallState` (the dynamic install/create axis derived
// from `ClawAvailability`) and from guest-image readiness. This axis answers a
// single static question the backend already decides: "can a user install this
// claw at all on this kind of host?". The backend `installable` field (theyos
// PR #88) is the SINGLE SOURCE OF TRUTH — the iOS client must NOT re-derive it
// from `tier` / `buildable` / claw name. See `Claw.installability`.

/// Machine-readable reason a claw cannot be installed, mirroring
/// `core_rs::manifest::UnavailableReasonCode`. Wire values are snake-case
/// strings. Unknown / future values decode to `.unknown` (fail-soft, same
/// idiom as `InstallStatus`) so a newer backend cannot break the decoder.
public enum ClawUnavailableReasonCode: String, Codable, Sendable, Equatable {
    case catalogOnly = "catalog_only"
    case detectedUnverified = "detected_unverified"
    case noInstallPlan = "no_install_plan"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ClawUnavailableReasonCode(rawValue: raw) ?? .unknown
    }
}

/// Resolved installability verdict for a claw. The UI gates the Install CTA on
/// `isInstallable` and renders copy keyed off `reasonCode` (never off the raw
/// backend `message`, which is operator-facing detail only).
public enum ClawInstallability: Equatable, Sendable {
    case installable
    case unavailable(reasonCode: ClawUnavailableReasonCode, message: String?)

    public var isInstallable: Bool {
        if case .installable = self { return true } else { return false }
    }
}

// MARK: - Claw (catalog + dynamic state)

public struct Claw: Codable, Identifiable, Sendable {
    public let name: String
    public let description: String
    public let language: String
    public let buildable: Bool

    public let version: String?
    public let binarySizeMb: Int?
    public let minRamMb: Int?
    public let license: String?
    public let updatedAt: String?

    public var availability: ClawAvailability

    // ─── Installability (theyos PR #88) ─────────────────────────────────────
    // Optional so an older engine that omits these keys still decodes. See
    // `installability` for the fail-open compat rule.
    public let installable: Bool?
    public let unavailableReasonCode: ClawUnavailableReasonCode?
    public let unavailableReason: String?

    public var id: String { name }

    public init(
        name: String,
        description: String,
        language: String,
        buildable: Bool,
        version: String?,
        binarySizeMb: Int?,
        minRamMb: Int?,
        license: String?,
        updatedAt: String?,
        availability: ClawAvailability,
        installable: Bool? = nil,
        unavailableReasonCode: ClawUnavailableReasonCode? = nil,
        unavailableReason: String? = nil
    ) {
        self.name = name
        self.description = description
        self.language = language
        self.buildable = buildable
        self.version = version
        self.binarySizeMb = binarySizeMb
        self.minRamMb = minRamMb
        self.license = license
        self.updatedAt = updatedAt
        self.availability = availability
        self.installable = installable
        self.unavailableReasonCode = unavailableReasonCode
        self.unavailableReason = unavailableReason
    }

    public var installState: ClawInstallState { ClawInstallState(availability) }

    /// Single source of truth for "can a user install this claw?". Derived
    /// ONLY from the backend `installable` field — never from tier/buildable/
    /// name. Views and ViewModels MUST consult this, not reinvent the rule.
    ///
    /// Compat: when `installable` is absent (pre-#88 engine), fail OPEN to
    /// `.installable`. This preserves the legacy behavior (no client-side
    /// gate) and avoids hiding legitimate claws on older servers; the backend
    /// install handler stays the authoritative backstop.
    public var installability: ClawInstallability {
        guard let installable else { return .installable }
        guard !installable else { return .installable }
        return .unavailable(
            reasonCode: unavailableReasonCode ?? .unknown,
            message: unavailableReason
        )
    }

    public var displayVersion: String { version ?? "—" }
    public var displayBinarySize: String {
        guard let mb = binarySizeMb else { return "—" }
        return "\(mb) MB"
    }
    public var displayMinRAM: String {
        guard let mb = minRamMb else { return "—" }
        return "\(mb) MB"
    }
    public var displayLicense: String { license ?? "—" }
    public var displayUpdatedAt: String {
        guard let raw = updatedAt else { return "—" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date)
        }
        return String(raw.prefix(10))
    }
}

// Identity-based Hashable/Equatable: `availability` mutates on every polling
// tick, so auto-synthesized Hashable would churn each tick and corrupt
// NavigationPath. Identity is `name` (== `id`), so equality is name-only.
extension Claw: Hashable {
    public static func == (lhs: Claw, rhs: Claw) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

public struct ClawsResponse: Decodable, Sendable {
    public let data: [Claw]

    public init(data: [Claw]) { self.data = data }
}

// MARK: - Resource Options (Server Limits)

public struct ResourceOption: Codable, Equatable, Sendable {
    public let min: Int
    public let max: Int
    public let `default`: Int
    public let disabled: Bool?

    public init(min: Int, max: Int, default: Int, disabled: Bool?) {
        self.min = min
        self.max = max
        self.default = `default`
        self.disabled = disabled
    }
}

public struct ResourceOptions: Codable, Equatable, Sendable {
    public let cpuCores: ResourceOption
    public let ramMb: ResourceOption
    public let diskGb: ResourceOption

    public init(cpuCores: ResourceOption, ramMb: ResourceOption, diskGb: ResourceOption) {
        self.cpuCores = cpuCores
        self.ramMb = ramMb
        self.diskGb = diskGb
    }
}

// MARK: - Users (Admin Assignment)

public struct ClawUser: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let role: String

    public init(id: String, username: String, role: String) {
        self.id = id
        self.username = username
        self.role = role
    }
}

public struct UsersResponse: Decodable, Sendable {
    public let data: [ClawUser]

    public init(data: [ClawUser]) { self.data = data }
}

// MARK: - Create Instance

public struct CreateInstanceRequest: Encodable, Sendable {
    public let name: String
    public let clawType: String
    public let guestOs: String?
    public let cpuCores: Int?
    public let ramMb: Int?
    public let diskGb: Int?
    public let ownerId: String?

    public init(name: String, clawType: String, guestOs: String?, cpuCores: Int?, ramMb: Int?, diskGb: Int?, ownerId: String?) {
        self.name = name
        self.clawType = clawType
        self.guestOs = guestOs
        self.cpuCores = cpuCores
        self.ramMb = ramMb
        self.diskGb = diskGb
        self.ownerId = ownerId
    }
}

public struct CreateInstanceResponse: Decodable, Sendable {
    public let id: String
    public let name: String
    public let container: String
    public let clawType: String?
    public let status: InstanceStatus
    public let jobId: String?

    public init(id: String, name: String, container: String, clawType: String?, status: InstanceStatus, jobId: String?) {
        self.id = id
        self.name = name
        self.container = container
        self.clawType = clawType
        self.status = status
        self.jobId = jobId
    }

    // Dual-shape decoder.
    //
    // Engine (`POST /api/v1/mobile/instances`) returns the fields flat:
    // `{id, name, container, claw_type, status, job_id}`.
    //
    // Admin host (`POST /api/v1/instances`) wraps them:
    // `{instance: {id, name, container, claw_type, status, ...}, job_id, message}`.
    //
    // The decoder is invoked with `.convertFromSnakeCase` (see
    // `SoyehtAPIClient.decoder`), so JSON keys land as camelCase before
    // key lookup. We try the admin (wrapped) shape first because
    // `instance` is the disambiguating field — present iff this is the
    // admin response.
    private enum TopKeys: String, CodingKey {
        case instance, jobId, id, name, container, clawType, status
    }

    private enum InstanceKeys: String, CodingKey {
        case id, name, container, clawType, status
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: TopKeys.self)
        if let nested = try? top.nestedContainer(keyedBy: InstanceKeys.self, forKey: .instance) {
            self.id = try nested.decode(String.self, forKey: .id)
            self.name = try nested.decode(String.self, forKey: .name)
            self.container = try nested.decode(String.self, forKey: .container)
            self.clawType = try nested.decodeIfPresent(String.self, forKey: .clawType)
            self.status = try nested.decode(InstanceStatus.self, forKey: .status)
            self.jobId = try top.decodeIfPresent(String.self, forKey: .jobId)
        } else {
            self.id = try top.decode(String.self, forKey: .id)
            self.name = try top.decode(String.self, forKey: .name)
            self.container = try top.decode(String.self, forKey: .container)
            self.clawType = try top.decodeIfPresent(String.self, forKey: .clawType)
            self.status = try top.decode(InstanceStatus.self, forKey: .status)
            self.jobId = try top.decodeIfPresent(String.self, forKey: .jobId)
        }
    }
}

// MARK: - Instance Status (Provisioning Poll)

public struct InstanceStatusResponse: Decodable, Sendable {
    public let status: InstanceStatus
    public let provisioningMessage: String?
    public let provisioningError: String?
    public let provisioningPhase: String?

    public init(status: InstanceStatus, provisioningMessage: String?, provisioningError: String?, provisioningPhase: String?) {
        self.status = status
        self.provisioningMessage = provisioningMessage
        self.provisioningError = provisioningError
        self.provisioningPhase = provisioningPhase
    }

    // Dual-shape decoder.
    //
    // Engine (`GET /api/v1/mobile/instances/{id}/status`) returns the
    // provisioning fields flat. Admin host
    // (`GET /api/v1/instances/{id}/status`) wraps them inside an
    // `instance` object alongside an optional `job` object. The decoder
    // runs with `.convertFromSnakeCase` so JSON `provisioning_message`
    // lands as `provisioningMessage` before key lookup.
    private enum TopKeys: String, CodingKey {
        case instance, status, provisioningMessage, provisioningError, provisioningPhase
    }

    private enum InstanceKeys: String, CodingKey {
        case status, provisioningMessage, provisioningError, provisioningPhase
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: TopKeys.self)
        if let nested = try? top.nestedContainer(keyedBy: InstanceKeys.self, forKey: .instance) {
            self.status = try nested.decode(InstanceStatus.self, forKey: .status)
            self.provisioningMessage = try nested.decodeIfPresent(String.self, forKey: .provisioningMessage)
            self.provisioningError = try nested.decodeIfPresent(String.self, forKey: .provisioningError)
            self.provisioningPhase = try nested.decodeIfPresent(String.self, forKey: .provisioningPhase)
        } else {
            self.status = try top.decode(InstanceStatus.self, forKey: .status)
            self.provisioningMessage = try top.decodeIfPresent(String.self, forKey: .provisioningMessage)
            self.provisioningError = try top.decodeIfPresent(String.self, forKey: .provisioningError)
            self.provisioningPhase = try top.decodeIfPresent(String.self, forKey: .provisioningPhase)
        }
    }
}

// MARK: - Instance Action

public enum InstanceAction: String, Sendable {
    case stop, restart, rebuild, delete
}

// MARK: - Assignment Target

public enum AssignmentTarget: Equatable, Sendable {
    case admin
    case existingUser(ClawUser)
}
