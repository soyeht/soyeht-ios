import Testing
import Foundation
@testable import Soyeht

@Suite("ClawModels", .serialized)
struct ClawModelsTests {

    // MARK: - Claw

    private var apiDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private var apiEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    private var creatableAvailabilityBlob: String {
        """
        "availability":{"name":"picoclaw","install":{"status":"succeeded","progress":null,"installed_at":"2026-03-15T10:00:00Z","error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"creatable"},"reasons":[],"degradations":[]}
        """
    }

    private var notInstalledAvailabilityBlob: String {
        """
        "availability":{"name":"b","install":{"status":"not_installed","progress":null,"installed_at":null,"error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"not_installed"},"reasons":[{"type":"not_installed"}],"degradations":[]}
        """
    }

    private var installingAvailabilityBlob: String {
        """
        "availability":{"name":"c","install":{"status":"installing","progress":{"phase":"downloading","percent":20,"bytes_downloaded":20000000,"bytes_total":100000000,"updated_at_ms":0},"installed_at":null,"error":null,"job_id":"j1"},"host":{"cold_path_ready":true,"has_golden":false,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"installing","percent":20},"reasons":[{"type":"install_in_progress","percent":20}],"degradations":[]}
        """
    }

    private var failedAvailabilityBlob: String {
        """
        "availability":{"name":"d","install":{"status":"failed","progress":null,"installed_at":null,"error":"build failed","job_id":"j1"},"host":{"cold_path_ready":true,"has_golden":false,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"failed","error":"build failed"},"reasons":[{"type":"install_failed","error":"build failed"}],"degradations":[]}
        """
    }

    @Test("Claw decodes from backend JSON with embedded availability")
    func clawDecodes() throws {
        let json = Data("""
        {"name":"picoclaw","description":"Lightweight Go-based assistant","language":"go","buildable":true,\(creatableAvailabilityBlob)}
        """.utf8)

        let claw = try apiDecoder.decode(Claw.self, from: json)
        #expect(claw.name == "picoclaw")
        #expect(claw.language == "go")
        #expect(claw.installState == .installed)
        #expect(claw.installState.isInstalled)
        #expect(claw.installState.canCreate)
        #expect(claw.installState.canUninstall)
        #expect(claw.availability.install.installedAt == "2026-03-15T10:00:00Z")
        #expect(claw.id == "picoclaw")
    }

    @Test("Claw installState maps install axis correctly across states")
    func clawInstallStateMapsAxes() throws {
        let readyJson = Data("""
        {"name":"a","description":"","language":"go","buildable":true,\(creatableAvailabilityBlob)}
        """.utf8)
        let notInstalledJson = Data("""
        {"name":"b","description":"","language":"go","buildable":true,\(notInstalledAvailabilityBlob)}
        """.utf8)
        let installingJson = Data("""
        {"name":"c","description":"","language":"go","buildable":true,\(installingAvailabilityBlob)}
        """.utf8)
        let failedJson = Data("""
        {"name":"d","description":"","language":"go","buildable":true,\(failedAvailabilityBlob)}
        """.utf8)

        let ready = try apiDecoder.decode(Claw.self, from: readyJson)
        let notInstalled = try apiDecoder.decode(Claw.self, from: notInstalledJson)
        let installing = try apiDecoder.decode(Claw.self, from: installingJson)
        let failed = try apiDecoder.decode(Claw.self, from: failedJson)

        #expect(ready.installState.isInstalled == true)
        #expect(ready.installState.canCreate == true)

        #expect(notInstalled.installState.isInstalled == false)
        #expect(notInstalled.installState.canCreate == false)

        #expect(installing.installState.isInstalled == false)
        #expect(installing.installState.isInstalling == true)
        #expect(installing.installState.isTransient == true)
        #expect(installing.installState.isTerminal == false)

        if case .installFailed(let err) = failed.installState {
            #expect(err == "build failed")
        } else {
            Issue.record("failed claw should be .installFailed")
        }
        #expect(failed.installState.isInstalled == false)
    }

    @Test("ClawsResponse decodes items wrapper")
    func clawsResponseDecodes() throws {
        let json = Data("""
        {"data":[
            {"name":"picoclaw","description":"Go-based","language":"go","buildable":true,\(creatableAvailabilityBlob)},
            {"name":"zeroclaw","description":"Rust-based","language":"rust","buildable":true,\(notInstalledAvailabilityBlob)}
        ]}
        """.utf8)

        let response = try apiDecoder.decode(ClawsResponse.self, from: json)
        #expect(response.data.count == 2)
        #expect(response.data[0].name == "picoclaw")
        #expect(response.data[0].installState.isInstalled == true)
        #expect(response.data[1].installState.isInstalled == false)
    }

    // MARK: - Identity Hashable

    @Test("Claw Hashable uses name only — mutating availability preserves hash")
    func clawHashableIsNameOnly() throws {
        let ready = Data("""
        {"name":"pico","description":"","language":"go","buildable":true,\(creatableAvailabilityBlob.replacingOccurrences(of: "\"picoclaw\"", with: "\"pico\""))}
        """.utf8)
        let installingVariant = Data("""
        {"name":"pico","description":"","language":"go","buildable":true,\(installingAvailabilityBlob.replacingOccurrences(of: "\"c\"", with: "\"pico\""))}
        """.utf8)

        let a = try apiDecoder.decode(Claw.self, from: ready)
        let b = try apiDecoder.decode(Claw.self, from: installingVariant)

        // Different install states, same name → still equal + same hash.
        // This is what keeps NavigationPath stable during polling mutations.
        #expect(a == b)
        var h1 = Hasher()
        a.hash(into: &h1)
        var h2 = Hasher()
        b.hash(into: &h2)
        #expect(h1.finalize() == h2.finalize())
    }

    // MARK: - ResourceOptions

    @Test("ResourceOptions decodes from API JSON")
    func resourceOptionsDecodes() throws {
        let json = Data("""
        {
            "cpu_cores": {"min": 1, "max": 12, "default": 3},
            "ram_mb": {"min": 768, "max": 24576, "default": 3072},
            "disk_gb": {"min": 15, "max": 180, "default": 30, "disabled": true}
        }
        """.utf8)

        let options = try apiDecoder.decode(ResourceOptions.self, from: json)
        #expect(options.cpuCores.min == 1)
        #expect(options.cpuCores.max == 12)
        #expect(options.cpuCores.default == 3)
        #expect(options.ramMb.min == 768)
        #expect(options.ramMb.max == 24576)
        #expect(options.ramMb.default == 3072)
        #expect(options.diskGb.min == 15)
        #expect(options.diskGb.max == 180)
        #expect(options.diskGb.default == 30)
        #expect(options.diskGb.disabled == true)
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
        {"data": [
            {"id": "u_1", "username": "admin", "role": "admin"},
            {"id": "u_2", "username": "joao", "role": "user"}
        ]}
        """.utf8)

        let response = try JSONDecoder().decode(UsersResponse.self, from: json)
        #expect(response.data.count == 2)
        #expect(response.data[0].username == "admin")
        #expect(response.data[1].role == "user")
    }

    // MARK: - CreateInstanceRequest

    @Test("CreateInstanceRequest encodes all fields")
    func createRequestEncodesAllFields() throws {
        let request = CreateInstanceRequest(
            name: "my-claw",
            clawType: "picoclaw",
            guestOs: "linux",
            cpuCores: 2,
            ramMb: 2048,
            diskGb: 10,
            ownerId: "u_abc"
        )
        let data = try apiEncoder.encode(request)
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
            clawType: "picoclaw",
            guestOs: nil,
            cpuCores: nil,
            ramMb: nil,
            diskGb: nil,
            ownerId: nil
        )
        let data = try apiEncoder.encode(request)
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

        let response = try apiDecoder.decode(CreateInstanceResponse.self, from: json)
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

        let response = try apiDecoder.decode(CreateInstanceResponse.self, from: json)
        #expect(response.clawType == nil)
    }

    // MARK: - InstanceStatusResponse

    @Test("InstanceStatusResponse decodes provisioning state with phase")
    func statusResponseDecodesProvisioning() throws {
        let json = Data("""
        {"status": "provisioning", "provisioning_message": "Pulling image...", "provisioning_error": null, "provisioning_phase": "pulling"}
        """.utf8)

        let response = try apiDecoder.decode(InstanceStatusResponse.self, from: json)
        #expect(response.status == "provisioning")
        #expect(response.provisioningMessage == "Pulling image...")
        #expect(response.provisioningError == nil)
        #expect(response.provisioningPhase == "pulling")
    }

    @Test("InstanceStatusResponse decodes active state with no extras")
    func statusResponseDecodesActive() throws {
        let json = Data("""
        {"status": "active"}
        """.utf8)

        let response = try apiDecoder.decode(InstanceStatusResponse.self, from: json)
        #expect(response.status == "active")
        #expect(response.provisioningMessage == nil)
        #expect(response.provisioningError == nil)
        #expect(response.provisioningPhase == nil)
    }

    // MARK: - Mock Data

    @Test("ClawMockData returns known info for picoclaw")
    func mockDataReturnsKnownInfo() {
        let info = ClawMockData.storeInfo(for: "picoclaw")
        #expect(info.language == "Go")
        #expect(info.rating == 0.0) // Ratings disabled until real API data
        #expect(!info.featured)
    }

    @Test("ClawMockData returns empty reviews (disabled until real API data)")
    func mockDataReturnsEmptyReviews() {
        let reviews = ClawMockData.reviews(for: "ironclaw")
        #expect(reviews.isEmpty)
    }

    @Test("ClawMockData returns empty reviews for unknown claw")
    func mockDataReturnsEmptyForUnknown() {
        let reviews = ClawMockData.reviews(for: "nonexistent")
        #expect(reviews.isEmpty)
    }
}

// MARK: - ClawAvailability decoder + ClawInstallState derivation
//
// Lives in the same file as ClawModelsTests so it ships with the existing
// SoyehtTests target without needing a new pbxproj entry. Logically distinct
// — exhaustive coverage of the new availability projection types and the
// two-axis ClawInstallState derivation (the heart of the refactor).

@Suite("ClawAvailability", .serialized)
struct ClawAvailabilityTests {

    private var apiDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    // MARK: - Decoder tests (real-shape fixtures)

    @Test("Installing payload decodes with typed status and phase")
    func installingDecodes() throws {
        let json = Data(#"""
        {"name":"hermes-agent","install":{"status":"installing","progress":{"phase":"downloading","percent":43,"bytes_downloaded":113145344,"bytes_total":263000000,"updated_at_ms":1744390012345},"installed_at":null,"error":null,"job_id":"job_abc"},"host":{"cold_path_ready":true,"has_golden":false,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"installing","percent":43},"reasons":[{"type":"install_in_progress","percent":43}],"degradations":[]}
        """#.utf8)
        let a = try apiDecoder.decode(ClawAvailability.self, from: json)
        #expect(a.install.status == .installing)
        #expect(a.install.progress?.phase == .downloading)
        #expect(a.install.progress?.percent == 43)
        #expect(a.install.progress?.bytesTotal == 263_000_000)
        if case .installing(let p) = a.overall { #expect(p == 43) } else { Issue.record("overall should be .installing") }
        #expect(a.reasons.first == .installInProgress(percent: 43))
    }

    @Test("Creatable payload decodes (succeeded + no host issues)")
    func creatableDecodes() throws {
        let json = Data(#"""
        {"name":"picoclaw","install":{"status":"succeeded","progress":null,"installed_at":"2026-04-01T00:00:00Z","error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"creatable"},"reasons":[],"degradations":[]}
        """#.utf8)
        let a = try apiDecoder.decode(ClawAvailability.self, from: json)
        #expect(a.install.status == .succeeded)
        #expect(a.overall == .creatable)
        #expect(a.reasons.isEmpty)
    }

    @Test("Installed-but-blocked by maintenance (realistic fixture)")
    func installedButBlockedMaintenance() throws {
        // Realistic maintenance: claw IS installed (install.status=succeeded),
        // host is syncing artifacts → creation blocked with retry-after.
        let json = Data(#"""
        {"name":"bar","install":{"status":"succeeded","progress":null,"installed_at":"2026-04-01T00:00:00Z","error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":true,"maintenance_retry_after_secs":60},"overall":{"state":"blocked"},"reasons":[{"type":"maintenance_mode","retry_after_secs":60}],"degradations":[]}
        """#.utf8)
        let a = try apiDecoder.decode(ClawAvailability.self, from: json)
        #expect(a.install.status == .succeeded)
        #expect(a.host.maintenanceBlocked == true)
        #expect(a.overall == .blocked)
        if case .maintenanceMode(let r) = a.reasons.first { #expect(r == 60) } else { Issue.record("reason should be .maintenanceMode(60)") }
    }

    @Test("Installed-but-blocked by missing cold path")
    func installedButBlockedNoColdPath() throws {
        let json = Data(#"""
        {"name":"foo","install":{"status":"succeeded","progress":null,"installed_at":"2026-04-01T00:00:00Z","error":null,"job_id":null},"host":{"cold_path_ready":false,"has_golden":false,"has_base_rootfs":false,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"blocked"},"reasons":[{"type":"no_cold_path_available"}],"degradations":[]}
        """#.utf8)
        let a = try apiDecoder.decode(ClawAvailability.self, from: json)
        #expect(a.overall == .blocked)
        #expect(a.reasons.first == .noColdPathAvailable)
    }

    @Test("Install failed decodes error string from install.error")
    func installFailed() throws {
        let json = Data(#"""
        {"name":"baz","install":{"status":"failed","progress":null,"installed_at":null,"error":"artifact 404","job_id":"job_x"},"host":{"cold_path_ready":true,"has_golden":false,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"failed","error":"artifact 404"},"reasons":[{"type":"install_failed","error":"artifact 404"}],"degradations":[]}
        """#.utf8)
        let a = try apiDecoder.decode(ClawAvailability.self, from: json)
        #expect(a.install.status == .failed)
        if case .failed(let e) = a.overall { #expect(e == "artifact 404") } else { Issue.record() }
    }

    @Test("Unknown discriminators fall through safely")
    func unknownDiscriminators() throws {
        let json = Data(#"""
        {"name":"future","install":{"status":"teleporting","progress":null,"installed_at":null,"error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"future_state_42"},"reasons":[{"type":"future_reason_99"}],"degradations":[{"type":"future_degradation"}]}
        """#.utf8)
        let a = try apiDecoder.decode(ClawAvailability.self, from: json)
        #expect(a.install.status == .unknown)
        #expect(a.overall == .unknown)
        #expect(a.reasons.first == .unknownType)
        if case .unknown(let s) = a.degradations.first { #expect(s == "future_degradation") } else { Issue.record() }
    }

    @Test("Degradation base_rootfs_missing_but_golden_present decodes")
    func degradationKnown() throws {
        let json = Data(#"""
        {"name":"foo","install":{"status":"succeeded","progress":null,"installed_at":"2026-04-01T00:00:00Z","error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":false,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"creatable"},"reasons":[],"degradations":[{"type":"base_rootfs_missing_but_golden_present"}]}
        """#.utf8)
        let a = try apiDecoder.decode(ClawAvailability.self, from: json)
        #expect(a.degradations.first == .baseRootfsMissingButGoldenPresent)
    }

    // MARK: - APIErrorBody tolerant decoding

    @Test("APIErrorBody decodes the full claw error contract")
    func apiErrorBodyFullContract() throws {
        let json = Data(#"""
        {"error":"claw type 'hermes-agent' is still installing (43%)","code":"INVALID_INPUT","reasons":[{"type":"install_in_progress","percent":43}]}
        """#.utf8)
        let body = try apiDecoder.decode(SoyehtAPIClient.APIErrorBody.self, from: json)
        #expect(body.error.contains("hermes-agent"))
        #expect(body.code == "INVALID_INPUT")
        #expect(body.reasons?.first == .installInProgress(percent: 43))
        #expect(body.retryAfterSecs == nil)
    }

    @Test("APIErrorBody decodes 503 maintenance with retryAfterSecs")
    func apiErrorBodyMaintenance() throws {
        let json = Data(#"""
        {"error":"service temporarily unavailable","code":"SERVICE_UNAVAILABLE","reasons":[{"type":"maintenance_mode","retry_after_secs":60}],"retry_after_secs":60}
        """#.utf8)
        let body = try apiDecoder.decode(SoyehtAPIClient.APIErrorBody.self, from: json)
        #expect(body.code == "SERVICE_UNAVAILABLE")
        #expect(body.retryAfterSecs == 60)
    }

    @Test("APIErrorBody preserves error+code when reasons vocabulary drifts")
    func apiErrorBodyTolerantReasons() throws {
        // Reasons array with unknown discriminator → individual reasons fall through
        // to .unknownType (handled by UnavailReason). Body still decodes.
        let json = Data(#"""
        {"error":"some new server error","code":"NEW_CODE","reasons":[{"type":"future_reason_xyz"}]}
        """#.utf8)
        let body = try apiDecoder.decode(SoyehtAPIClient.APIErrorBody.self, from: json)
        #expect(body.error == "some new server error")
        #expect(body.code == "NEW_CODE")
        #expect(body.reasons?.first == .unknownType)
    }

    @Test("APIErrorBody decodes minimal body (only error string)")
    func apiErrorBodyMinimal() throws {
        let json = Data(#"""
        {"error":"server down"}
        """#.utf8)
        let body = try apiDecoder.decode(SoyehtAPIClient.APIErrorBody.self, from: json)
        #expect(body.error == "server down")
        #expect(body.code == nil)
        #expect(body.reasons == nil)
        #expect(body.retryAfterSecs == nil)
    }

    // MARK: - ClawInstallState derivation (two-axis semantics)

    private func avail(
        install: InstallStatus,
        overall: OverallState,
        reasons: [UnavailReason] = [],
        installError: String? = nil
    ) -> ClawAvailability {
        ClawAvailability(
            name: "x",
            install: InstallProjection(status: install, progress: nil, installedAt: nil, error: installError, jobId: nil),
            host: HostProjection(coldPathReady: true, hasGolden: true, hasBaseRootfs: true, maintenanceBlocked: false, maintenanceRetryAfterSecs: nil),
            overall: overall, reasons: reasons, degradations: []
        )
    }

    @Test("succeeded + creatable → .installed (isInstalled ∧ canCreate)")
    func stateInstalled() {
        let s = ClawInstallState(avail(install: .succeeded, overall: .creatable))
        #expect(s == .installed)
        #expect(s.isInstalled)
        #expect(s.canCreate)
        #expect(s.canUninstall)
        #expect(s.isTerminal)
    }

    @Test("succeeded + blocked → .installedButBlocked (isInstalled ∧ ¬canCreate)")
    func stateInstalledButBlocked() {
        let s = ClawInstallState(avail(install: .succeeded, overall: .blocked, reasons: [.maintenanceMode(retryAfterSecs: 60)]))
        if case .installedButBlocked(let r) = s {
            #expect(r.first == .maintenanceMode(retryAfterSecs: 60))
        } else {
            Issue.record("expected .installedButBlocked")
        }
        #expect(s.isInstalled)         // KEY: still counted as installed
        #expect(!s.canCreate)          // but cannot create
        #expect(s.canUninstall)        // uninstall still valid
        #expect(s.isTerminal)
    }

    @Test("installing → .installing (not terminal)")
    func stateInstalling() {
        let s = ClawInstallState(avail(install: .installing, overall: .installing(percent: 42)))
        #expect(s.isInstalling)
        #expect(s.isTransient)
        #expect(!s.isTerminal)
        #expect(!s.isInstalled)
        #expect(!s.canCreate)
    }

    // MARK: - Error source precedence in .installFailed

    @Test("failed with install.error takes precedence over overall.error")
    func stateFailedInstallErrorPrecedence() {
        let a = avail(
            install: .failed,
            overall: .failed(error: "different overall message"),
            installError: "artifact 404"
        )
        let s = ClawInstallState(a)
        if case .installFailed(let e) = s {
            #expect(e == "artifact 404")
        } else {
            Issue.record("expected .installFailed")
        }
    }

    @Test("failed with only overall.error falls through to overall source")
    func stateFailedOverallErrorFallback() {
        let a = avail(
            install: .failed,
            overall: .failed(error: "overall-only message"),
            installError: nil
        )
        let s = ClawInstallState(a)
        if case .installFailed(let e) = s {
            #expect(e == "overall-only message")
        } else {
            Issue.record("expected .installFailed")
        }
    }

    @Test("failed with no error source falls through to \"unknown\"")
    func stateFailedNoError() {
        let a = avail(install: .failed, overall: .notInstalled, installError: nil)
        let s = ClawInstallState(a)
        if case .installFailed(let e) = s {
            #expect(e == "unknown")
        } else {
            Issue.record("expected .installFailed")
        }
        #expect(!s.isInstalled)
        #expect(s.isTerminal)
    }

    @Test("not_installed → .notInstalled")
    func stateNotInstalled() {
        let s = ClawInstallState(avail(install: .notInstalled, overall: .notInstalled))
        #expect(s == .notInstalled)
        #expect(!s.isInstalled)
        #expect(s.isTerminal)
    }

    // MARK: - .uninstalling explicit state

    @Test("uninstalling → .uninstalling (counts as installed, transient)")
    func stateUninstalling() {
        let s = ClawInstallState(avail(install: .uninstalling, overall: .blocked))
        #expect(s == .uninstalling)
        #expect(s.isUninstalling)
        #expect(!s.isInstalling)
        #expect(s.isInstalled)         // still on host during transition
        #expect(!s.canCreate)
        #expect(!s.canUninstall)       // already uninstalling; can't re-queue
        #expect(s.isTransient)         // polling should stay active
        #expect(!s.isTerminal)
    }

    // MARK: - Fail-fast unknown handling (both axes)

    @Test("install.status = unknown + overall = unknown → .unknown (both drift)")
    func stateUnknownBothAxes() {
        let s = ClawInstallState(avail(install: .unknown, overall: .unknown))
        #expect(s == .unknown)
        #expect(s.isTerminal)          // deliberately terminal — polling stops
        #expect(!s.isInstalling)
        #expect(!s.isInstalled)
    }

    @Test("install.status = succeeded + overall = unknown → .unknown (mixed drift)")
    func stateMixedUnknownOnOverall() {
        // Regression: succeeded + overall.unknown was previously mapped to
        // .installedButBlocked, swallowing drift. Fail-fast must fire.
        let s = ClawInstallState(avail(install: .succeeded, overall: .unknown))
        #expect(s == .unknown)
    }

    @Test("install.status = not_installed + overall = unknown → .unknown")
    func stateMixedUnknownOnOverallAtNotInstalled() {
        let s = ClawInstallState(avail(install: .notInstalled, overall: .unknown))
        #expect(s == .unknown)
    }

    @Test("install.status = unknown + overall = creatable → .unknown")
    func stateMixedUnknownOnInstall() {
        let s = ClawInstallState(avail(install: .unknown, overall: .creatable))
        #expect(s == .unknown)
    }

    // MARK: - Two-axis independence regression

    @Test("installedCount axis is based on isInstalled, NOT canCreate")
    func installedCountAxis() {
        let creatable = ClawInstallState(avail(install: .succeeded, overall: .creatable))
        let blocked = ClawInstallState(avail(install: .succeeded, overall: .blocked, reasons: [.noColdPathAvailable]))
        let installing = ClawInstallState(avail(install: .installing, overall: .installing(percent: 10)))

        // Both creatable and blocked count as "installed" in the install axis.
        #expect(creatable.isInstalled)
        #expect(blocked.isInstalled)
        #expect(!installing.isInstalled)

        // Only creatable has canCreate.
        #expect(creatable.canCreate)
        #expect(!blocked.canCreate)
    }
}
