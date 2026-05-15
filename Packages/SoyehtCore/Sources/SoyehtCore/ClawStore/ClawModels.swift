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
        availability: ClawAvailability
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
    }

    public var installState: ClawInstallState { ClawInstallState(availability) }

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
    public let status: String
    public let jobId: String?

    public init(id: String, name: String, container: String, clawType: String?, status: String, jobId: String?) {
        self.id = id
        self.name = name
        self.container = container
        self.clawType = clawType
        self.status = status
        self.jobId = jobId
    }
}

// MARK: - Instance Status (Provisioning Poll)

public struct InstanceStatusResponse: Decodable, Sendable {
    public let status: String
    public let provisioningMessage: String?
    public let provisioningError: String?
    public let provisioningPhase: String?

    public init(status: String, provisioningMessage: String?, provisioningError: String?, provisioningPhase: String?) {
        self.status = status
        self.provisioningMessage = provisioningMessage
        self.provisioningError = provisioningError
        self.provisioningPhase = provisioningPhase
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
