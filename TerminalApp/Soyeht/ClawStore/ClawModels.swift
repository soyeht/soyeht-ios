import Foundation

// MARK: - Typed install status / phase
//
// InstallStatus mirrors `install.status` in the backend ClawAvailability
// projection. Unknown string values fall through to `.unknown` so a future
// backend value does not hard-crash the decoder, but ClawInstallState treats
// `.unknown` as terminal (fail-fast contract-drift defense — adding a new
// value in the backend MUST be mirrored here, not absorbed transitorily).

enum InstallStatus: String, Codable, Hashable {
    case notInstalled = "not_installed"
    case installing
    case succeeded
    case failed
    case uninstalling
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InstallStatus(rawValue: raw) ?? .unknown
    }
}

enum InstallPhase: String, Codable, Hashable {
    case downloading
    case verifying
    case finalizing
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InstallPhase(rawValue: raw) ?? .unknown
    }
}

// MARK: - Claw Availability Projection
//
// Single source of truth for dynamic claw state. Mirrors core_rs::availability.
// Tagged enums (OverallState, UnavailReason, Degradation) use manual Codable
// because JSON discriminators are `state` / `type`.

struct ClawAvailability: Codable, Equatable, Hashable {
    let name: String
    let install: InstallProjection
    let host: HostProjection
    let overall: OverallState
    let reasons: [UnavailReason]
    let degradations: [Degradation]
}

struct InstallProjection: Codable, Equatable, Hashable {
    let status: InstallStatus
    let progress: InstallProgress?
    let installedAt: String?
    let error: String?
    let jobId: String?
}

struct InstallProgress: Codable, Equatable, Hashable {
    let phase: InstallPhase
    let percent: Int
    let bytesDownloaded: Int
    let bytesTotal: Int
    let updatedAtMs: Int

    var fraction: Double { max(0, min(1, Double(percent) / 100.0)) }
    var downloadedMB: Int { bytesDownloaded / 1_000_000 }
    var totalMB: Int { bytesTotal / 1_000_000 }
    var hasBytes: Bool { bytesTotal > 0 }
}

struct HostProjection: Codable, Equatable, Hashable {
    let coldPathReady: Bool
    let hasGolden: Bool
    let hasBaseRootfs: Bool
    let maintenanceBlocked: Bool
    let maintenanceRetryAfterSecs: Int?
}

// Tagged enum with discriminator `state`. Manual Codable.
enum OverallState: Codable, Equatable, Hashable {
    case creatable
    case installing(percent: Int)
    case notInstalled
    case failed(error: String)
    case blocked
    case unknown

    private enum CodingKeys: String, CodingKey { case state, percent, error }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

// Tagged enum with discriminator `type`. Manual Codable.
enum UnavailReason: Codable, Equatable, Hashable {
    case unknownType
    case notInstalled
    case installInProgress(percent: Int)
    case installFailed(error: String)
    case noColdPathAvailable
    case maintenanceMode(retryAfterSecs: Int)

    private enum CodingKeys: String, CodingKey { case type, percent, error, retryAfterSecs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "unknown_type":           self = .unknownType
        case "not_installed":          self = .notInstalled
        case "install_in_progress":    self = .installInProgress(percent: try c.decodeIfPresent(Int.self, forKey: .percent) ?? 0)
        case "install_failed":         self = .installFailed(error: try c.decodeIfPresent(String.self, forKey: .error) ?? "unknown")
        case "no_cold_path_available": self = .noColdPathAvailable
        case "maintenance_mode":       self = .maintenanceMode(retryAfterSecs: try c.decodeIfPresent(Int.self, forKey: .retryAfterSecs) ?? 30)
        default:                       self = .unknownType
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknownType:              try c.encode("unknown_type",           forKey: .type)
        case .notInstalled:             try c.encode("not_installed",          forKey: .type)
        case .installInProgress(let p): try c.encode("install_in_progress",    forKey: .type); try c.encode(p, forKey: .percent)
        case .installFailed(let e):     try c.encode("install_failed",         forKey: .type); try c.encode(e, forKey: .error)
        case .noColdPathAvailable:      try c.encode("no_cold_path_available", forKey: .type)
        case .maintenanceMode(let r):   try c.encode("maintenance_mode",       forKey: .type); try c.encode(r, forKey: .retryAfterSecs)
        }
    }

    /// Short, user-facing message. Monospaced terminal aesthetic of the app.
    var displayMessage: String {
        switch self {
        case .unknownType:              return "unknown claw type"
        case .notInstalled:             return "not installed on this server"
        case .installInProgress(let p): return "installing (\(p)%)"
        case .installFailed(let e):     return "install failed: \(e)"
        case .noColdPathAvailable:      return "server is missing the base image — contact admin"
        case .maintenanceMode(let r):   return "server is syncing artifacts — retry in \(r)s"
        }
    }
}

enum Degradation: Codable, Equatable, Hashable {
    case baseRootfsMissingButGoldenPresent
    case unknown(String)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "base_rootfs_missing_but_golden_present":
            self = .baseRootfsMissingButGoldenPresent
        default:
            self = .unknown(tag)
        }
    }

    func encode(to encoder: Encoder) throws {
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
//
// Use `isInstalled` / `canCreate` / `canUninstall` / `isTransient` / `isTerminal`
// to query each axis without pattern-matching everywhere.

enum ClawInstallState: Equatable {
    case notInstalled
    case installing(InstallProgress?)
    case uninstalling
    case installed
    case installedButBlocked(reasons: [UnavailReason])
    case installFailed(error: String)
    case unknown

    init(_ availability: ClawAvailability) {
        // FAIL-FAST: drift on EITHER axis becomes .unknown. This check must
        // come BEFORE the main switch to prevent cases like
        //   install.status == .succeeded + overall == .unknown
        // from silently resolving to .installedButBlocked. If the backend
        // introduces a new discriminator, the corresponding enum here MUST be
        // updated — .unknown is deliberately terminal, not a transitory catchall.
        if availability.install.status == .unknown { self = .unknown; return }
        if case .unknown = availability.overall    { self = .unknown; return }

        switch availability.install.status {
        case .installing:
            self = .installing(availability.install.progress)

        case .uninstalling:
            // Active removal transition. Still on the host (counts as installed),
            // no actions available until the transition completes.
            self = .uninstalling

        case .failed:
            // Error source precedence: install.error (canonical) → overall.failed(error)
            // (fallback if backend populated only that side) → literal "unknown".
            let installErr = availability.install.error
            let overallErr: String? = {
                if case .failed(let e) = availability.overall { return e }
                return nil
            }()
            self = .installFailed(error: installErr ?? overallErr ?? "unknown")

        case .succeeded:
            // Installed. Consult overall to decide creatability. Note that
            // .unknown on overall was already caught by the fail-fast above.
            if case .creatable = availability.overall {
                self = .installed
            } else {
                self = .installedButBlocked(reasons: availability.reasons)
            }

        case .notInstalled:
            self = .notInstalled

        case .unknown:
            // Unreachable — captured by fail-fast above. Here for exhaustive switch.
            self = .unknown
        }
    }

    var isInstalling: Bool {
        if case .installing = self { return true } else { return false }
    }

    var isUninstalling: Bool {
        if case .uninstalling = self { return true } else { return false }
    }

    /// True whenever the claw is on the host — installed, blocked, or
    /// uninstalling. Gate of "installed" counts and footers.
    var isInstalled: Bool {
        switch self {
        case .installed, .installedButBlocked, .uninstalling: return true
        default: return false
        }
    }

    /// True only when the user can create an instance right now. Gate of the
    /// "deploy" button. NEVER use for "is installed" logic.
    var canCreate: Bool {
        if case .installed = self { return true } else { return false }
    }

    /// Uninstall is only valid when the claw is installed AND stable. Uninstalling
    /// does not count (already in flight); installing does not count either.
    var canUninstall: Bool {
        switch self {
        case .installed, .installedButBlocked: return true
        default: return false
        }
    }

    /// Transient = backend action in progress (install or uninstall). Polling
    /// should stay active. The client tracks both directions of transition.
    var isTransient: Bool { isInstalling || isUninstalling }

    /// Polling stop condition. `.unknown` is deliberately terminal — fail-fast
    /// contract-drift defense, not future-proof accommodation.
    var isTerminal: Bool { !isTransient }
}

// MARK: - Claw (slim catalog + authoritative dynamic state)

struct Claw: Codable, Identifiable {
    // Catalog (static, immutable)
    let name: String
    let description: String
    let language: String
    let buildable: Bool

    // Catalog spec fields (may be nil on servers that don't populate them)
    let version: String?
    let binarySizeMb: Int?
    let minRamMb: Int?
    let license: String?
    let updatedAt: String?

    // Dynamic state — polling writes here in-place. Required: fail-fast
    // on any backend that doesn't populate availability (contract drift).
    var availability: ClawAvailability

    var id: String { name }

    /// Single source of UI truth. Views and view-models read from this.
    var installState: ClawInstallState { ClawInstallState(availability) }

    // MARK: - Formatted display helpers (catalog-only)

    var displayVersion: String { version ?? "—" }
    var displayBinarySize: String {
        guard let mb = binarySizeMb else { return "—" }
        return "\(mb) MB"
    }
    var displayMinRAM: String {
        guard let mb = minRamMb else { return "—" }
        return "\(mb) MB"
    }
    var displayLicense: String { license ?? "—" }
    var displayUpdatedAt: String {
        guard let raw = updatedAt else { return "—" }
        // Try ISO8601 first, then date-only.
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

// MARK: - Identity-based Hashable/Equatable
//
// Claw is used as navigation route value via `ClawRoute.detail(Claw)`. Since
// `availability` mutates on every polling tick, an auto-synthesized Hashable
// would churn each tick and corrupt NavigationPath. Identity is `name` (which
// is also `id`), so `==` and `hash(into:)` are name-only. Tests that need full
// value comparison should assert specific fields, not use `==` on Claw.

extension Claw: Hashable {
    static func == (lhs: Claw, rhs: Claw) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

struct ClawsResponse: Decodable {
    let data: [Claw]
}

// MARK: - Resource Options (Server Limits)

struct ResourceOption: Codable, Equatable {
    let min: Int
    let max: Int
    let `default`: Int

    private enum CodingKeys: String, CodingKey {
        case min, max, `default`
    }
}

struct ResourceOptions: Codable, Equatable {
    let cpuCores: ResourceOption
    let ramMb: ResourceOption
    let diskGb: ResourceOption
}

struct ResourceOptionsResponse: Decodable {
    let cpuCores: ResourceOption
    let ramMb: ResourceOption
    let diskGb: ResourceOption
}

// MARK: - Users (Admin Assignment)

struct ClawUser: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let role: String
}

struct UsersResponse: Decodable {
    let data: [ClawUser]
}

// MARK: - Create Instance

struct CreateInstanceRequest: Encodable {
    let name: String
    let clawType: String
    let guestOs: String?
    let cpuCores: Int?
    let ramMb: Int?
    let diskGb: Int?
    let ownerId: String?
}

struct CreateInstanceResponse: Decodable {
    let id: String
    let name: String
    let container: String
    let clawType: String?
    let status: String
    let jobId: String?
}

// MARK: - Instance Status (Provisioning Poll)

struct InstanceStatusResponse: Decodable {
    let status: String
    let provisioningMessage: String?
    let provisioningError: String?
    let provisioningPhase: String?
}

// MARK: - Instance Action

enum InstanceAction: String {
    case stop, restart, rebuild, delete
}

// MARK: - Assignment Target

enum AssignmentTarget: Equatable {
    case admin
    case existingUser(ClawUser)
}
