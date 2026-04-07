import Testing
import Foundation
@testable import Soyeht

// MARK: - Isolated Mock URL Protocol (separate from ClawAPITests)

private final class VMTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var mockResponseData: Data = Data("{}".utf8)
    nonisolated(unsafe) static var mockStatusCode: Int = 200
    nonisolated(unsafe) static var routeOverrides: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var capturedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var bodyData = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 1024)
                if read > 0 { bodyData.append(buffer, count: read) }
                else { break }
            }
            stream.close()
            captured.httpBody = bodyData
        }
        VMTestURLProtocol.capturedRequest = captured

        var statusCode = VMTestURLProtocol.mockStatusCode
        var data = VMTestURLProtocol.mockResponseData

        if let path = request.url?.path {
            var bestMatch: (Int, Data)?
            var bestLen = 0
            for (prefix, override_) in VMTestURLProtocol.routeOverrides {
                if path.contains(prefix) && prefix.count > bestLen {
                    bestMatch = override_
                    bestLen = prefix.count
                }
            }
            if let match = bestMatch {
                statusCode = match.0
                data = match.1
            }
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        mockResponseData = Data("{}".utf8)
        mockStatusCode = 200
        routeOverrides = [:]
        capturedRequest = nil
    }
}

// MARK: - Test Helpers

private func makeClaw(_ name: String, status: String = "ready", description: String = "test") -> Claw {
    Claw(name: name, description: description, language: "go", buildable: true, status: status, installedAt: nil, jobId: nil, error: nil, version: nil, binarySizeMb: nil, minRamMb: nil, license: nil, updatedAt: nil)
}

private func makeVMTestClient(store: SessionStore? = nil) -> (SoyehtAPIClient, SessionStore) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VMTestURLProtocol.self]
    let session = URLSession(configuration: config)
    let s = store ?? SessionStore()
    s.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")
    return (SoyehtAPIClient(session: session, store: s), s)
}

private let clawsJSON = Data("""
{"items":[
    {"name":"picoclaw","description":"Go-based","language":"go","buildable":true,"status":"ready","installed_at":null,"job_id":null,"error":null},
    {"name":"ironclaw","description":"Rust-based","language":"rust","buildable":true,"status":"not_installed","installed_at":null,"job_id":null,"error":null}
]}
""".utf8)

private let installingClawsJSON = Data("""
{"items":[
    {"name":"picoclaw","description":"Go-based","language":"go","buildable":true,"status":"installing","installed_at":null,"job_id":"job_1","error":null}
]}
""".utf8)

private let readyClawsJSON = Data("""
{"items":[
    {"name":"picoclaw","description":"Go-based","language":"go","buildable":true,"status":"ready","installed_at":"2026-04-05T10:00:00Z","job_id":null,"error":null}
]}
""".utf8)

private let failedClawsJSON = Data("""
{"items":[
    {"name":"picoclaw","description":"Go-based","language":"go","buildable":true,"status":"failed","installed_at":null,"job_id":null,"error":"build failed"}
]}
""".utf8)

private let provisioningStatusJSON = Data("""
{"status":"provisioning","provisioning_message":"Pulling image...","provisioning_error":null,"provisioning_phase":"pulling"}
""".utf8)

private let activeStatusJSON = Data("""
{"status":"active","provisioning_message":null,"provisioning_error":null,"provisioning_phase":null}
""".utf8)

// MARK: - Sync ViewModel Tests (no mock protocol, safe to run in parallel)

@Suite("ClawStoreViewModel")
struct ClawStoreViewModelTests {

    @Test("featuredClaw returns the claw marked as featured in mock data")
    func featuredClawReturnsMockFeatured() {
        let vm = ClawStoreViewModel()
        vm.claws = [
            makeClaw("ironclaw", description: "Rust-based"),
            makeClaw("picoclaw", description: "Go-based"),
        ]
        #expect(vm.featuredClaw?.name == "ironclaw")
    }

    @Test("trendingClaws returns non-featured claws (max 2)")
    func trendingClawsReturnsNonFeatured() {
        let vm = ClawStoreViewModel()
        vm.claws = [
            makeClaw("ironclaw", description: "a"),
            makeClaw("picoclaw", description: "b"),
            makeClaw("nullclaw", status: "not_installed", description: "c"),
            makeClaw("zeroclaw", description: "d"),
        ]
        #expect(vm.trendingClaws.count == 2)
        #expect(vm.trendingClaws.allSatisfy { $0.name != "ironclaw" })
    }

    @Test("moreClaws excludes featured and trending")
    func moreClawsExcludesFeaturedAndTrending() {
        let vm = ClawStoreViewModel()
        vm.claws = [
            makeClaw("ironclaw", description: "a"),
            makeClaw("picoclaw", description: "b"),
            makeClaw("nullclaw", status: "not_installed", description: "c"),
            makeClaw("zeroclaw", description: "d"),
            makeClaw("shadowclaw", status: "not_installed", description: "e"),
        ]
        let moreNames = vm.moreClaws.map(\.name)
        #expect(!moreNames.contains("ironclaw"))
        #expect(moreNames.count >= 1)
    }

    @Test("availableCount and installedCount are correct")
    func countsAreCorrect() {
        let vm = ClawStoreViewModel()
        vm.claws = [
            makeClaw("a", description: "x"),
            makeClaw("b", status: "not_installed", description: "y"),
            makeClaw("c", description: "z"),
        ]
        #expect(vm.availableCount == 3)
        #expect(vm.installedCount == 2)
    }
}

@Suite("ClawSetupViewModel")
struct ClawSetupViewModelTests {

    @Test("initial clawName is derived from claw name")
    func initialClawName() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))
        #expect(vm.clawName == "picoclaw-workspace")
    }

    @Test("canDeploy is false when clawName is empty")
    func canDeployFalseWhenNameEmpty() {
        let store = SessionStore()
        let server = PairedServer(id: "s1-test", host: "test.host", name: "test", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "tok")
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), store: store)
        vm.clawName = "   "
        #expect(vm.canDeploy == false)
    }

    @Test("canDeploy is true with valid name and server")
    func canDeployTrueWithValidData() {
        let store = SessionStore()
        let server = PairedServer(id: "s-deploy-check", host: "deploy.host", name: "deploy", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "tok")
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), store: store)
        vm.selectedServerIndex = store.pairedServers.firstIndex(where: { $0.id == "s-deploy-check" }) ?? 0
        #expect(vm.canDeploy == true)
    }

    @Test("deploySucceeded is false initially")
    func deploySucceededInitiallyFalse() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))
        #expect(vm.deploySucceeded == false)
    }

    // MARK: - Name Validation

    @Test("nameValidationError returns nil for empty name")
    func nameValidation_emptyIsNotError() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))
        vm.clawName = ""
        #expect(vm.nameValidationError == nil)
        #expect(vm.canDeploy == false)
    }

    @Test("nameValidationError returns error for names longer than 64 chars")
    func nameValidation_tooLong() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))
        vm.clawName = String(repeating: "a", count: 65)
        #expect(vm.nameValidationError != nil)
        #expect(vm.canDeploy == false)
    }

    @Test("nameValidationError returns error for special characters")
    func nameValidation_specialChars() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))
        vm.clawName = "my@claw!"
        #expect(vm.nameValidationError != nil)
    }

    @Test("nameValidationError returns nil for valid hyphenated name")
    func nameValidation_validHyphenated() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))
        vm.clawName = "my-claw-1"
        #expect(vm.nameValidationError == nil)
    }
}

@Suite("ClawDetailViewModel")
struct ClawDetailViewModelTests {

    @Test("storeInfo returns correct data for known claw")
    func storeInfoReturnsCorrectData() {
        let vm = ClawDetailViewModel(claw: makeClaw("ironclaw", description: "test"))
        #expect(vm.storeInfo.language == "Rust")
        #expect(vm.storeInfo.rating == 4.9)
        #expect(vm.storeInfo.featured == true)
    }

    @Test("reviews returns mock reviews")
    func reviewsReturnsMockReviews() {
        let vm = ClawDetailViewModel(claw: makeClaw("ironclaw", description: "test"))
        #expect(vm.reviews.count == 3)
        #expect(vm.reviews[0].author == "paulo.marcos")
    }

    @Test("claw display helpers format spec fields")
    func clawDisplayHelpersFormatSpecs() {
        let claw = Claw(name: "picoclaw", description: "test", language: "go", buildable: true, status: "ready", installedAt: nil, jobId: nil, error: nil, version: "v1.8.3", binarySizeMb: 12, minRamMb: 256, license: "MIT", updatedAt: "2026-03-20T00:00:00Z")
        #expect(claw.displayVersion == "v1.8.3")
        #expect(claw.displayLicense == "MIT")
        #expect(claw.displayBinarySize == "12 MB")
        #expect(claw.displayMinRAM == "256 MB")
        #expect(claw.displayUpdatedAt == "2026-03-20")
    }

    @Test("claw display helpers return dash for nil fields")
    func clawDisplayHelpersReturnDashForNil() {
        let claw = makeClaw("unknown", description: "test")
        #expect(claw.displayVersion == "—")
        #expect(claw.displayLicense == "—")
        #expect(claw.displayBinarySize == "—")
        #expect(claw.displayMinRAM == "—")
        #expect(claw.displayUpdatedAt == "—")
    }
}

// MARK: - ALL Async ViewModel Tests (single serialized suite to prevent mock state races)

@Suite("ClawViewModelAsync", .serialized)
struct ClawViewModelAsyncTests {

    // MARK: - ClawStoreViewModel

    @Test("loadClaws populates claws on success")
    @MainActor
    func loadClaws_populatesClawsOnSuccess() async throws {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client)
        await vm.loadClaws()

        try #require(vm.claws.count == 2)
        #expect(vm.claws[0].name == "picoclaw")
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    @Test("loadClaws sets errorMessage on failure")
    @MainActor
    func loadClaws_setsErrorOnFailure() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockStatusCode = 500
        VMTestURLProtocol.mockResponseData = Data("{\"error\":\"server down\"}".utf8)

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client)
        await vm.loadClaws()

        #expect(vm.claws.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage != nil)
    }

    @Test("installClaw sets no actionError on success")
    @MainActor
    func installClaw_noActionErrorOnSuccess() async {
        VMTestURLProtocol.reset()
        let installJSON = Data("{\"job_id\":\"job_1\",\"message\":\"install queued\"}".utf8)
        VMTestURLProtocol.routeOverrides["/install"] = (200, installJSON)
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client)
        await vm.installClaw(makeClaw("picoclaw", status: "not_installed", description: "test"))

        #expect(vm.actionError == nil)
    }

    @Test("installClaw sets actionError on HTTP error")
    @MainActor
    func installClaw_setsActionErrorOnHttpError() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockStatusCode = 403
        VMTestURLProtocol.mockResponseData = Data("{\"error\":\"admin access required\"}".utf8)

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client)
        await vm.installClaw(makeClaw("picoclaw", status: "not_installed", description: "test"))

        #expect(vm.actionError != nil)
    }

    @Test("uninstallClaw sets no actionError on success")
    @MainActor
    func uninstallClaw_noActionErrorOnSuccess() async {
        VMTestURLProtocol.reset()
        let uninstallJSON = Data("{\"job_id\":\"job_2\",\"message\":\"uninstall queued\"}".utf8)
        VMTestURLProtocol.routeOverrides["/uninstall"] = (200, uninstallJSON)
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client)
        await vm.uninstallClaw(makeClaw("picoclaw", description: "test"))

        #expect(vm.actionError == nil)
    }

    // MARK: - ClawSetupViewModel

    @Test("loadOptions sets resource defaults from API response")
    @MainActor
    func loadOptions_setsResourceDefaults() async {
        VMTestURLProtocol.reset()
        let resourceJSON = Data("""
        {"cpu_cores":{"min":1,"max":8,"default":4},"ram_mb":{"min":256,"max":4096,"default":1024},"disk_gb":{"min":10,"max":100,"default":20}}
        """.utf8)
        VMTestURLProtocol.routeOverrides["/resource-options"] = (200, resourceJSON)
        VMTestURLProtocol.routeOverrides["/users"] = (200, Data("{\"users\":[]}".utf8))
        VMTestURLProtocol.mockResponseData = resourceJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), apiClient: client)
        await vm.loadOptions()

        #expect(vm.cpuCores == 4)
        #expect(vm.ramMB == 1024)
        #expect(vm.diskGB == 20)
        #expect(vm.resourceOptions != nil)
        #expect(vm.resourceOptionsWarning == nil)
    }

    @Test("loadOptions sets warning on API failure")
    @MainActor
    func loadOptions_setsWarningOnFailure() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockStatusCode = 500
        VMTestURLProtocol.mockResponseData = Data("{\"error\":\"server error\"}".utf8)

        let (client, _) = makeVMTestClient()
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), apiClient: client)
        await vm.loadOptions()

        #expect(vm.resourceOptionsWarning != nil)
        #expect(vm.cpuCores == 2)
        #expect(vm.ramMB == 2048)
        #expect(vm.diskGB == 10)
    }

    @Test("deploy sets deploySucceeded on success")
    @MainActor
    func deploy_setsDeploySucceeded() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = Data("""
        {"id":"inst_xyz","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"active"}
        """.utf8)

        let store = SessionStore()
        let server = PairedServer(id: "s-deploy-test", host: "test.example.com", name: "test", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")

        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), apiClient: client, store: store)
        vm.selectedServerIndex = store.pairedServers.firstIndex(where: { $0.id == "s-deploy-test" }) ?? 0

        await vm.deploy()

        #expect(vm.deploySucceeded == true)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - ClawDetailViewModel

    @Test("installClaw transitions state correctly")
    @MainActor
    func detailInstallClaw_updatesState() async {
        VMTestURLProtocol.reset()
        let installJSON = Data("{\"job_id\":\"job_1\",\"message\":\"install queued\"}".utf8)
        VMTestURLProtocol.routeOverrides["/install"] = (200, installJSON)
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawDetailViewModel(claw: makeClaw("picoclaw", status: "not_installed", description: "test"), apiClient: client)
        await vm.installClaw()

        #expect(vm.isPerformingAction == false)
        #expect(vm.actionError == nil)
    }

    @Test("uninstallClaw transitions state correctly")
    @MainActor
    func detailUninstallClaw_updatesState() async {
        VMTestURLProtocol.reset()
        let uninstallJSON = Data("{\"job_id\":\"job_2\",\"message\":\"uninstall queued\"}".utf8)
        VMTestURLProtocol.routeOverrides["/uninstall"] = (200, uninstallJSON)
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawDetailViewModel(claw: makeClaw("picoclaw", description: "test"), apiClient: client)
        await vm.uninstallClaw()

        #expect(vm.isPerformingAction == false)
        #expect(vm.actionError == nil)
    }

    // MARK: - Polling Tests: ClawStoreViewModel

    @Test("polling starts when claws are installing")
    @MainActor
    func polling_startsWhenClawsInstalling() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client, sleeper: { _ in })
        await vm.loadClaws()

        #expect(vm.isPolling == true)
        #expect(vm.hasInstallingClaws == true)
    }

    @Test("polling does not start when all claws ready")
    @MainActor
    func polling_doesNotStartWhenAllReady() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = readyClawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client, sleeper: { _ in })
        await vm.loadClaws()

        #expect(vm.isPolling == false)
    }

    @Test("polling stops when all claws become ready")
    @MainActor
    func polling_stopsWhenAllReady() async throws {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(apiClient: client, sleeper: { _ in })
        await vm.loadClaws()
        #expect(vm.isPolling == true)

        // Change mock to return ready — polling loop will pick it up
        VMTestURLProtocol.mockResponseData = readyClawsJSON
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms for task to cycle

        #expect(vm.isPolling == false)
        #expect(vm.claws.first?.installed == true)
    }

    @Test("polling sends success notification on completion")
    @MainActor
    func polling_sendsSuccessNotification() async throws {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        var notifications: [(String, Bool)] = []
        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(
            apiClient: client,
            sleeper: { _ in },
            onInstallComplete: { name, success in notifications.append((name, success)) }
        )
        await vm.loadClaws()

        VMTestURLProtocol.mockResponseData = readyClawsJSON
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(notifications.contains(where: { $0.0 == "picoclaw" && $0.1 == true }))
    }

    @Test("polling sends failure notification on failed")
    @MainActor
    func polling_sendsFailureNotification() async throws {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        var notifications: [(String, Bool)] = []
        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(
            apiClient: client,
            sleeper: { _ in },
            onInstallComplete: { name, success in notifications.append((name, success)) }
        )
        await vm.loadClaws()

        VMTestURLProtocol.mockResponseData = failedClawsJSON
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(notifications.contains(where: { $0.0 == "picoclaw" && $0.1 == false }))
    }

    // MARK: - Polling Tests: ClawDetailViewModel

    @Test("detail polling starts on install")
    @MainActor
    func detailPolling_startsOnInstall() async {
        VMTestURLProtocol.reset()
        let installJSON = Data("{\"job_id\":\"job_1\",\"message\":\"install queued\"}".utf8)
        VMTestURLProtocol.routeOverrides["/install"] = (200, installJSON)
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawDetailViewModel(
            claw: makeClaw("picoclaw", status: "not_installed", description: "test"),
            apiClient: client,
            sleeper: { _ in }
        )
        await vm.installClaw()

        #expect(vm.isPolling == true)
    }

    @Test("detail polling stops and notifies on completion")
    @MainActor
    func detailPolling_stopsAndNotifies() async throws {
        VMTestURLProtocol.reset()
        let installJSON = Data("{\"job_id\":\"job_1\",\"message\":\"install queued\"}".utf8)
        VMTestURLProtocol.routeOverrides["/install"] = (200, installJSON)
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        var notifications: [(String, Bool)] = []
        let (client, _) = makeVMTestClient()
        let vm = ClawDetailViewModel(
            claw: makeClaw("picoclaw", status: "not_installed", description: "test"),
            apiClient: client,
            sleeper: { _ in },
            onInstallComplete: { name, success in notifications.append((name, success)) }
        )
        await vm.installClaw()
        #expect(vm.isPolling == true)

        // Transition to ready
        VMTestURLProtocol.mockResponseData = readyClawsJSON
        VMTestURLProtocol.routeOverrides = [:]
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(vm.isPolling == false)
        #expect(notifications.contains(where: { $0.0 == "picoclaw" && $0.1 == true }))
    }

    // MARK: - Deploy hands off to ClawDeployMonitor

    @Test("deploy hands off to monitor and sets deploySucceeded")
    @MainActor
    func deploy_handsOffToMonitor() async throws {
        VMTestURLProtocol.reset()
        let createJSON = Data("""
        {"id":"inst_1","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"provisioning"}
        """.utf8)
        VMTestURLProtocol.mockResponseData = createJSON

        let store = SessionStore()
        let server = PairedServer(id: "s-monitor-test", host: "test.example.com", name: "test", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")

        let monitor = ClawDeployMonitor(apiClient: .shared)
        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), apiClient: client, store: store, deployMonitor: monitor)
        vm.selectedServerIndex = 0

        await vm.deploy()

        #expect(vm.isDeploying == false)
        #expect(vm.deploySucceeded == true)
        #expect(vm.errorMessage == nil)
        #expect(monitor.activeDeploys.contains(where: { $0.id == "inst_1" }))
    }

    // MARK: - macOS deploy omits disk_gb (Bug #3)

    @Test("deploy with macOS server type sends nil disk_gb")
    @MainActor
    func deploy_macosOmitsDiskGB() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = Data("""
        {"id":"inst_mac","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"active"}
        """.utf8)

        let store = SessionStore()
        let server = PairedServer(id: "s-mac-test", host: "test.example.com", name: "test", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")

        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), apiClient: client, store: store)
        vm.selectedServerIndex = store.pairedServers.firstIndex(where: { $0.id == "s-mac-test" }) ?? 0
        vm.serverType = "macos"

        await vm.deploy()

        let request = VMTestURLProtocol.capturedRequest
        if let body = request?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["disk_gb"] == nil, "disk_gb should be omitted for macOS")
            #expect(json["guest_os"] as? String == "macos")
        }
    }
}
