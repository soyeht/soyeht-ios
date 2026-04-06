import Testing
import Foundation
@testable import Soyeht

@Suite("ClawModels", .serialized)
struct ClawModelsTests {

    // MARK: - Claw

    private var snakeDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    @Test("Claw decodes from backend JSON with snake_case")
    func clawDecodes() throws {
        let json = Data("""
        {"name":"picoclaw","description":"Lightweight Go-based assistant","language":"go","buildable":true,"status":"ready","installed_at":"2026-03-15T10:00:00Z","job_id":null,"error":null}
        """.utf8)

        let claw = try snakeDecoder.decode(Claw.self, from: json)
        #expect(claw.name == "picoclaw")
        #expect(claw.language == "go")
        #expect(claw.status == "ready")
        #expect(claw.installed == true)
        #expect(claw.isInstalling == false)
        #expect(claw.installedAt == "2026-03-15T10:00:00Z")
        #expect(claw.id == "picoclaw")
    }

    @Test("Claw installed computed property maps status correctly")
    func clawInstalledMapsStatus() throws {
        let readyJson = Data("""
        {"name":"a","description":"","language":"go","buildable":true,"status":"ready","installed_at":null,"job_id":null,"error":null}
        """.utf8)
        let notInstalledJson = Data("""
        {"name":"b","description":"","language":"go","buildable":true,"status":"not_installed","installed_at":null,"job_id":null,"error":null}
        """.utf8)
        let installingJson = Data("""
        {"name":"c","description":"","language":"go","buildable":true,"status":"installing","installed_at":null,"job_id":"j1","error":null}
        """.utf8)
        let failedJson = Data("""
        {"name":"d","description":"","language":"go","buildable":true,"status":"failed","installed_at":null,"job_id":null,"error":"build failed"}
        """.utf8)

        let ready = try snakeDecoder.decode(Claw.self, from: readyJson)
        let notInstalled = try snakeDecoder.decode(Claw.self, from: notInstalledJson)
        let installing = try snakeDecoder.decode(Claw.self, from: installingJson)
        let failed = try snakeDecoder.decode(Claw.self, from: failedJson)

        #expect(ready.installed == true)
        #expect(notInstalled.installed == false)
        #expect(installing.installed == false)
        #expect(installing.isInstalling == true)
        #expect(failed.installed == false)
        #expect(failed.isFailed == true)
    }

    @Test("ClawsResponse decodes items wrapper")
    func clawsResponseDecodes() throws {
        let json = Data("""
        {"items":[
            {"name":"picoclaw","description":"Go-based","language":"go","buildable":true,"status":"ready","installed_at":null,"job_id":null,"error":null},
            {"name":"zeroclaw","description":"Rust-based","language":"rust","buildable":true,"status":"not_installed","installed_at":null,"job_id":null,"error":null}
        ]}
        """.utf8)

        let response = try snakeDecoder.decode(ClawsResponse.self, from: json)
        #expect(response.items.count == 2)
        #expect(response.items[0].name == "picoclaw")
        #expect(response.items[0].installed == true)
        #expect(response.items[1].installed == false)
    }

    // MARK: - ResourceOptions

    @Test("ResourceOptions decodes from API JSON")
    func resourceOptionsDecodes() throws {
        let json = Data("""
        {
            "cpu_cores": {"min": 1, "max": 4, "default": 2},
            "ram_mb": {"min": 512, "max": 8192, "default": 2048},
            "disk_gb": {"min": 5, "max": 50, "default": 10}
        }
        """.utf8)

        let options = try JSONDecoder().decode(ResourceOptions.self, from: json)
        #expect(options.cpu_cores.min == 1)
        #expect(options.cpu_cores.max == 4)
        #expect(options.cpu_cores.default == 2)
        #expect(options.ram_mb.min == 512)
        #expect(options.ram_mb.max == 8192)
        #expect(options.ram_mb.default == 2048)
        #expect(options.disk_gb.min == 5)
        #expect(options.disk_gb.max == 50)
        #expect(options.disk_gb.default == 10)
    }

    // MARK: - ClawUser

    @Test("ClawUser decodes from JSON")
    func clawUserDecodes() throws {
        let json = Data("""
        {"id": "u_abc123", "username": "admin", "role": "admin"}
        """.utf8)

        let user = try JSONDecoder().decode(ClawUser.self, from: json)
        #expect(user.id == "u_abc123")
        #expect(user.username == "admin")
        #expect(user.role == "admin")
    }

    @Test("UsersResponse decodes wrapped array")
    func usersResponseDecodes() throws {
        let json = Data("""
        {"users": [
            {"id": "u_1", "username": "admin", "role": "admin"},
            {"id": "u_2", "username": "joao", "role": "user"}
        ]}
        """.utf8)

        let response = try JSONDecoder().decode(UsersResponse.self, from: json)
        #expect(response.users.count == 2)
        #expect(response.users[0].username == "admin")
        #expect(response.users[1].role == "user")
    }

    // MARK: - CreateInstanceRequest

    @Test("CreateInstanceRequest encodes all fields")
    func createRequestEncodesAllFields() throws {
        let request = CreateInstanceRequest(
            name: "my-claw",
            claw_type: "picoclaw",
            guest_os: "linux",
            cpu_cores: 2,
            ram_mb: 2048,
            disk_gb: 10,
            owner_id: "u_abc"
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["name"] as? String == "my-claw")
        #expect(json["claw_type"] as? String == "picoclaw")
        #expect(json["guest_os"] as? String == "linux")
        #expect(json["cpu_cores"] as? Int == 2)
        #expect(json["ram_mb"] as? Int == 2048)
        #expect(json["disk_gb"] as? Int == 10)
        #expect(json["owner_id"] as? String == "u_abc")
    }

    @Test("CreateInstanceRequest encodes nil optional fields as null")
    func createRequestEncodesNilFields() throws {
        let request = CreateInstanceRequest(
            name: "my-claw",
            claw_type: "picoclaw",
            guest_os: nil,
            cpu_cores: nil,
            ram_mb: nil,
            disk_gb: nil,
            owner_id: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["name"] as? String == "my-claw")
        #expect(json["claw_type"] as? String == "picoclaw")
    }

    // MARK: - CreateInstanceResponse

    @Test("CreateInstanceResponse decodes with snake_case claw_type")
    func createResponseDecodesSnakeCase() throws {
        let json = Data("""
        {
            "id": "inst_xyz",
            "name": "my-claw",
            "container": "picoclaw-my-claw",
            "claw_type": "picoclaw",
            "status": "provisioning"
        }
        """.utf8)

        let response = try JSONDecoder().decode(CreateInstanceResponse.self, from: json)
        #expect(response.id == "inst_xyz")
        #expect(response.name == "my-claw")
        #expect(response.container == "picoclaw-my-claw")
        #expect(response.clawType == "picoclaw")
        #expect(response.status == "provisioning")
    }

    @Test("CreateInstanceResponse handles missing clawType")
    func createResponseHandlesMissingClawType() throws {
        let json = Data("""
        {"id": "inst_1", "name": "test", "container": "c", "status": "active"}
        """.utf8)

        let response = try JSONDecoder().decode(CreateInstanceResponse.self, from: json)
        #expect(response.clawType == nil)
    }

    // MARK: - InstanceStatusResponse

    @Test("InstanceStatusResponse decodes provisioning state with phase")
    func statusResponseDecodesProvisioning() throws {
        let json = Data("""
        {"status": "provisioning", "provisioning_message": "Pulling image...", "provisioning_error": null, "provisioning_phase": "pulling"}
        """.utf8)

        let response = try JSONDecoder().decode(InstanceStatusResponse.self, from: json)
        #expect(response.status == "provisioning")
        #expect(response.provisioning_message == "Pulling image...")
        #expect(response.provisioning_error == nil)
        #expect(response.provisioning_phase == "pulling")
    }

    @Test("InstanceStatusResponse decodes active state with no extras")
    func statusResponseDecodesActive() throws {
        let json = Data("""
        {"status": "active"}
        """.utf8)

        let response = try JSONDecoder().decode(InstanceStatusResponse.self, from: json)
        #expect(response.status == "active")
        #expect(response.provisioning_message == nil)
        #expect(response.provisioning_error == nil)
        #expect(response.provisioning_phase == nil)
    }

    // MARK: - Mock Data

    @Test("ClawMockData returns known info for picoclaw")
    func mockDataReturnsKnownInfo() {
        let info = ClawMockData.storeInfo(for: "picoclaw")
        #expect(info.language == "Go")
        #expect(info.rating == 4.3)
        #expect(!info.featured)
    }

    @Test("ClawMockData returns reviews for ironclaw")
    func mockDataReturnsReviews() {
        let reviews = ClawMockData.reviews(for: "ironclaw")
        #expect(reviews.count == 3)
        #expect(reviews[0].author == "paulo.marcos")
    }

    @Test("ClawMockData returns empty reviews for unknown claw")
    func mockDataReturnsEmptyForUnknown() {
        let reviews = ClawMockData.reviews(for: "nonexistent")
        #expect(reviews.isEmpty)
    }
}
