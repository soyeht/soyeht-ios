import Foundation

// MARK: - Claw (AI Assistant Type)

struct Claw: Codable, Identifiable, Hashable {
    let name: String
    let description: String
    let language: String
    let buildable: Bool
    let status: String
    let installedAt: String?
    let jobId: String?
    let error: String?

    var id: String { name }

    /// Claw is installed and ready to deploy
    var installed: Bool { status == "ready" }

    /// Claw is currently being installed
    var isInstalling: Bool { status == "installing" }

    /// Installation failed
    var isFailed: Bool { status == "failed" }
}

struct ClawsResponse: Decodable {
    let items: [Claw]
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
    let cpu_cores: ResourceOption
    let ram_mb: ResourceOption
    let disk_gb: ResourceOption
}

struct ResourceOptionsResponse: Decodable {
    let cpu_cores: ResourceOption
    let ram_mb: ResourceOption
    let disk_gb: ResourceOption
}

// MARK: - Users (Admin Assignment)

struct ClawUser: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let role: String
}

struct UsersResponse: Decodable {
    let users: [ClawUser]
}

// MARK: - Create Instance

struct CreateInstanceRequest: Encodable {
    let name: String
    let claw_type: String
    let guest_os: String?
    let cpu_cores: Int?
    let ram_mb: Int?
    let disk_gb: Int?
    let owner_id: String?
}

struct CreateInstanceResponse: Decodable {
    let id: String
    let name: String
    let container: String
    let clawType: String?
    let status: String
    let jobId: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, container, status
        case clawType = "claw_type"
        case jobId = "job_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        container = try c.decode(String.self, forKey: .container)
        status = try c.decode(String.self, forKey: .status)
        clawType = try c.decodeIfPresent(String.self, forKey: .clawType)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
    }
}

// MARK: - Instance Status (Provisioning Poll)

struct InstanceStatusResponse: Decodable {
    let status: String
    let provisioning_message: String?
    let provisioning_error: String?
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
