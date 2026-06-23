import Testing
import Foundation
import SoyehtCore
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
            let hostPath = "\(request.url?.host ?? "")\(path)"
            var bestMatch: (Int, Data)?
            var bestLen = 0
            for (prefix, override_) in VMTestURLProtocol.routeOverrides {
                if (hostPath.contains(prefix) || path.contains(prefix)) && prefix.count > bestLen {
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
        // Keep host-scoped overrides (`host/path`) stable across resets:
        // these tests run alongside other suites, and a generic reset in a
        // parallel test must not erase another test's unique host route.
        routeOverrides = routeOverrides.filter { !$0.key.hasPrefix("/") }
        capturedRequest = nil
    }
}

/// Polls `condition` every 20ms until it returns true or the timeout expires.
/// Used after flipping a mock response to wait for the view model's polling
/// loop to cycle. On timeout, records an issue so the failure diagnostic is
/// explicit (distinguishing timeout from a bad assertion) and allows the
/// downstream `#expect` to still fire with its own details.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 10.0,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    if !condition() {
        Issue.record("waitUntil timed out after \(timeout)s")
    }
}

// MARK: - Test Helpers

/// High-level test state describing what kind of Claw the test needs.
/// `makeClaw` translates this into a full ClawAvailability payload.
private enum MockClawState {
    case installed
    case notInstalled
    case installing(percent: Int)
    case uninstalling
    case failed(String)
    case installedButBlocked(reasons: [UnavailReason])
}

private func makeAvailability(
    installStatus: InstallStatus = .succeeded,
    progress: InstallProgress? = nil,
    overall: OverallState = .creatable,
    reasons: [UnavailReason] = [],
    host: HostProjection? = nil,
    installError: String? = nil,
    jobId: String? = nil,
    installedAt: String? = nil
) -> ClawAvailability {
    ClawAvailability(
        name: "stub",
        install: InstallProjection(
            status: installStatus,
            progress: progress,
            installedAt: installedAt ?? (installStatus == .succeeded ? "2026-01-01T00:00:00Z" : nil),
            error: installError,
            jobId: jobId
        ),
        host: host ?? HostProjection(
            coldPathReady: true,
            hasGolden: true,
            hasBaseRootfs: true,
            maintenanceBlocked: false,
            maintenanceRetryAfterSecs: nil
        ),
        overall: overall,
        reasons: reasons,
        degradations: []
    )
}

private func makeClaw(
    _ name: String,
    state: MockClawState = .installed,
    description: String = "test",
    installable: Bool? = nil,
    unavailableReasonCode: ClawUnavailableReasonCode? = nil,
    unavailableReason: String? = nil
) -> Claw {
    let avail: ClawAvailability = {
        switch state {
        case .installed:
            return makeAvailability(installStatus: .succeeded, overall: .creatable)

        case .notInstalled:
            return makeAvailability(
                installStatus: .notInstalled,
                overall: .notInstalled,
                reasons: [.notInstalled],
                installedAt: nil
            )

        case .installing(let percent):
            let progress = InstallProgress(
                phase: .downloading,
                percent: percent,
                bytesDownloaded: percent * 1_000_000,
                bytesTotal: 100_000_000,
                updatedAtMs: 0
            )
            return makeAvailability(
                installStatus: .installing,
                progress: progress,
                overall: .installing(percent: percent),
                reasons: [.installInProgress(percent: percent)],
                jobId: "job_1",
                installedAt: nil
            )

        case .uninstalling:
            return makeAvailability(
                installStatus: .uninstalling,
                overall: .blocked,
                reasons: [],
                jobId: "job_uninstall"
            )

        case .failed(let err):
            return makeAvailability(
                installStatus: .failed,
                overall: .failed(error: err),
                reasons: [.installFailed(error: err)],
                installError: err,
                installedAt: nil
            )

        case .installedButBlocked(let reasons):
            // Installed on the host, but something is preventing creation.
            let maintenanceBlocked = reasons.contains {
                if case .maintenanceMode = $0 { return true } else { return false }
            }
            let retryAfter = reasons.compactMap { r -> Int? in
                if case .maintenanceMode(let r) = r { return r } else { return nil }
            }.first
            let host = HostProjection(
                coldPathReady: !reasons.contains(.noColdPathAvailable),
                hasGolden: true,
                hasBaseRootfs: !reasons.contains(.noColdPathAvailable),
                maintenanceBlocked: maintenanceBlocked,
                maintenanceRetryAfterSecs: retryAfter
            )
            return makeAvailability(
                installStatus: .succeeded,
                overall: .blocked,
                reasons: reasons,
                host: host
            )
        }
    }()

    return Claw(
        name: name,
        description: description,
        language: "go",
        buildable: true,
        version: nil,
        binarySizeMb: nil,
        minRamMb: nil,
        license: nil,
        updatedAt: nil,
        availability: avail,
        installable: installable,
        unavailableReasonCode: unavailableReasonCode,
        unavailableReason: unavailableReason
    )
}

private func makeVMTestClient(store: SoyehtCore.SessionStore? = nil) -> (SoyehtCore.SoyehtAPIClient, SoyehtCore.SessionStore) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VMTestURLProtocol.self]
    let session = URLSession(configuration: config)
    let s = store ?? makeIsolatedSoyehtCoreSessionStore()
    let server = SoyehtCore.PairedServer(
        id: "test-server-original",
        host: "test.example.com",
        name: "test",
        role: "admin",
        pairedAt: Date(),
        expiresAt: nil
    )
    s.addServer(server, token: "test-token-123")
    s.setActiveServer(id: server.id)
    return (SoyehtCore.SoyehtAPIClient(session: session, store: s), s)
}

private func vmRoute(host: String, _ pathSuffix: String) -> String {
    "\(host)/api/v1/mobile\(pathSuffix)"
}

// Fixture helper — generates a Claw JSON object with embedded availability.
private func clawJSON(
    name: String,
    language: String = "go",
    description: String = "test",
    availabilityJSON: String
) -> String {
    """
    {"name":"\(name)","description":"\(description)","language":"\(language)","buildable":true,"availability":\(availabilityJSON)}
    """
}

private let creatablePicoAvailability = """
{"name":"picoclaw","install":{"status":"succeeded","progress":null,"installed_at":"2026-01-01T00:00:00Z","error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"creatable"},"reasons":[],"degradations":[]}
"""

private let notInstalledIronAvailability = """
{"name":"ironclaw","install":{"status":"not_installed","progress":null,"installed_at":null,"error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":false,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"not_installed"},"reasons":[{"type":"not_installed"}],"degradations":[]}
"""

private let installingPicoAvailability = """
{"name":"picoclaw","install":{"status":"installing","progress":{"phase":"downloading","percent":43,"bytes_downloaded":43000000,"bytes_total":100000000,"updated_at_ms":1744390012345},"installed_at":null,"error":null,"job_id":"job_1"},"host":{"cold_path_ready":true,"has_golden":false,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"installing","percent":43},"reasons":[{"type":"install_in_progress","percent":43}],"degradations":[]}
"""

private let readyPicoAvailability = """
{"name":"picoclaw","install":{"status":"succeeded","progress":null,"installed_at":"2026-04-05T10:00:00Z","error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"creatable"},"reasons":[],"degradations":[]}
"""

private let failedPicoAvailability = """
{"name":"picoclaw","install":{"status":"failed","progress":null,"installed_at":null,"error":"build failed","job_id":"job_1"},"host":{"cold_path_ready":true,"has_golden":false,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"failed","error":"build failed"},"reasons":[{"type":"install_failed","error":"build failed"}],"degradations":[]}
"""

private let clawsJSON = Data("""
{"data":[
    \(clawJSON(name: "picoclaw", language: "go", description: "Go-based", availabilityJSON: creatablePicoAvailability)),
    \(clawJSON(name: "ironclaw", language: "rust", description: "Rust-based", availabilityJSON: notInstalledIronAvailability))
]}
""".utf8)

private let installingClawsJSON = Data("""
{"data":[
    \(clawJSON(name: "picoclaw", language: "go", description: "Go-based", availabilityJSON: installingPicoAvailability))
]}
""".utf8)

private let readyClawsJSON = Data("""
{"data":[
    \(clawJSON(name: "picoclaw", language: "go", description: "Go-based", availabilityJSON: readyPicoAvailability))
]}
""".utf8)

private let failedClawsJSON = Data("""
{"data":[
    \(clawJSON(name: "picoclaw", language: "go", description: "Go-based", availabilityJSON: failedPicoAvailability))
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
        let vm = ClawStoreViewModel(context: makeTestServerContext())
        vm.claws = [
            makeClaw("ironclaw", description: "Rust-based"),
            makeClaw("picoclaw", description: "Go-based"),
        ]
        #expect(vm.featuredClaw?.name == "ironclaw")
    }

    @Test("trendingClaws returns non-featured claws (max 2)")
    func trendingClawsReturnsNonFeatured() {
        let vm = ClawStoreViewModel(context: makeTestServerContext())
        vm.claws = [
            makeClaw("ironclaw", description: "a"),
            makeClaw("picoclaw", description: "b"),
            makeClaw("nullclaw", state: .notInstalled, description: "c"),
            makeClaw("zeroclaw", description: "d"),
        ]
        #expect(vm.trendingClaws.count == 2)
        #expect(vm.trendingClaws.allSatisfy { $0.name != "ironclaw" })
    }

    @Test("moreClaws excludes featured and trending")
    func moreClawsExcludesFeaturedAndTrending() {
        let vm = ClawStoreViewModel(context: makeTestServerContext())
        vm.claws = [
            makeClaw("ironclaw", description: "a"),
            makeClaw("picoclaw", description: "b"),
            makeClaw("nullclaw", state: .notInstalled, description: "c"),
            makeClaw("zeroclaw", description: "d"),
            makeClaw("shadowclaw", state: .notInstalled, description: "e"),
        ]
        let moreNames = vm.moreClaws.map(\.name)
        #expect(!moreNames.contains("ironclaw"))
        #expect(moreNames.count >= 1)
    }

    @Test("availableCount and installedCount are correct")
    func countsAreCorrect() {
        let vm = ClawStoreViewModel(context: makeTestServerContext())
        vm.claws = [
            makeClaw("a", description: "x"),
            makeClaw("b", state: .notInstalled, description: "y"),
            makeClaw("c", description: "z"),
        ]
        #expect(vm.availableCount == 3)
        #expect(vm.installedCount == 2)
    }

    // MARK: - installedButBlocked regression tests (core of the refactor)

    @Test("installedButBlocked counts in installedCount")
    func installedButBlockedCountsAsInstalled() {
        let vm = ClawStoreViewModel(context: makeTestServerContext())
        vm.claws = [
            makeClaw("a", state: .installed),
            makeClaw("b", state: .installedButBlocked(reasons: [.noColdPathAvailable])),
            makeClaw("c", state: .notInstalled),
        ]
        // Both a and b are on the host — isInstalled axis, NOT canCreate axis.
        #expect(vm.installedCount == 2)
    }

    @Test("uninstalling counts in installedCount during transition")
    func uninstallingCountsAsInstalledDuringTransition() {
        let vm = ClawStoreViewModel(context: makeTestServerContext())
        vm.claws = [
            makeClaw("a", state: .installed),
            makeClaw("b", state: .uninstalling),
            makeClaw("c", state: .notInstalled),
        ]
        // Uninstalling claws are still on the host until the transition completes.
        #expect(vm.installedCount == 2)
    }

    @Test("hasTransientClaws is true when any claw is installing or uninstalling")
    func hasTransientClawsCoversBothTransitions() {
        let vm = ClawStoreViewModel(context: makeTestServerContext())
        vm.claws = [
            makeClaw("a", state: .installed),
            makeClaw("b", state: .installing(percent: 50)),
        ]
        #expect(vm.hasTransientClaws == true)

        vm.claws = [
            makeClaw("a", state: .installed),
            makeClaw("b", state: .uninstalling),
        ]
        #expect(vm.hasTransientClaws == true)

        vm.claws = [makeClaw("a", state: .installed)]
        #expect(vm.hasTransientClaws == false)
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
        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(id: "s1-test", host: "test.host", name: "test", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "tok")
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), store: store)
        vm.clawName = "   "
        #expect(vm.canDeploy == false)
    }

    @Test("canDeploy is true with valid name and server")
    func canDeployTrueWithValidData() {
        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(id: "s-deploy-check", host: "deploy.host", name: "deploy", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "tok")
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), store: store)
        vm.selectedServerIndex = store.pairedServers.firstIndex(where: { $0.id == "s-deploy-check" }) ?? 0
        #expect(vm.canDeploy == true)
    }

    @Test("selected server constrains agent OS choices")
    func selectedServerConstrainsAgentOSChoices() {
        let store = makeIsolatedSoyehtCoreSessionStore()
        let mac = PairedServer(id: "s-mac-sync", host: "mac.local", name: "Mac", role: "admin", pairedAt: Date(), expiresAt: nil, platform: "macos")
        let linux = PairedServer(id: "s-linux-sync", host: "linux.local", name: "Linux", role: "admin", pairedAt: Date(), expiresAt: nil, platform: "linux")
        store.addServer(mac, token: "mac-token")
        store.addServer(linux, token: "linux-token")

        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), store: store)
        #expect(vm.selectedServer?.id == "s-mac-sync")
        #expect(vm.serverType == "macos")

        vm.selectServerType("linux")
        #expect(vm.serverType == "linux")

        vm.selectServerType("macos")
        #expect(vm.serverType == "macos")

        vm.selectServer(at: 1)

        #expect(vm.selectedServer?.id == "s-linux-sync")
        #expect(vm.availableServerTypes == ["linux"])
        #expect(vm.serverType == "linux")

        vm.selectServerType("macos")
        #expect(vm.serverType == "linux")

        let linuxDefault = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: "s-linux-sync",
            store: store
        )
        #expect(linuxDefault.selectedServer?.id == "s-linux-sync")
        #expect(linuxDefault.serverType == "linux")
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
        let vm = ClawDetailViewModel(claw: makeClaw("ironclaw", description: "test"), context: makeTestServerContext())
        #expect(vm.storeInfo.language == "Rust")
        #expect(vm.storeInfo.rating == 0.0) // Ratings disabled until real API data
        #expect(vm.storeInfo.featured == true)
    }

    @Test("reviews returns empty (disabled until real API data)")
    func reviewsReturnsEmpty() {
        let vm = ClawDetailViewModel(claw: makeClaw("ironclaw", description: "test"), context: makeTestServerContext())
        #expect(vm.reviews.isEmpty)
    }

    @Test("claw display helpers format spec fields")
    func clawDisplayHelpersFormatSpecs() {
        let claw = Claw(
            name: "picoclaw",
            description: "test",
            language: "go",
            buildable: true,
            version: "v1.8.3",
            binarySizeMb: 12,
            minRamMb: 256,
            license: "MIT",
            updatedAt: "2026-03-20T00:00:00Z",
            availability: makeAvailability()
        )
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

    @Test("installedButBlocked claw exposes isInstalled + canUninstall + !canCreate")
    func installedButBlockedDetailFlags() {
        let claw = makeClaw(
            "picoclaw",
            state: .installedButBlocked(reasons: [.maintenanceMode(retryAfterSecs: 60)])
        )
        let vm = ClawDetailViewModel(
            claw: claw,
            context: makeTestServerContext(),
            pairedServerCountProvider: { 2 }
        )
        // These flags drive the action-button branch selection in ClawDetailView:
        // isInstalled=true → footer count includes this claw
        // canCreate=false → deploy button hidden
        // canUninstall=true → uninstall button still shown
        #expect(vm.claw.installState.isInstalled)
        #expect(!vm.claw.installState.canCreate)
        #expect(vm.claw.installState.canUninstall)
        #expect(vm.installedServerCount == 2)
        #expect(vm.totalServerCount == 2)
    }

    @Test("detail count default reads canonical ServerStore inventory")
    func detailCountDefaultUsesServerStoreInventory() throws {
        let source = try coreSource("ClawStore/ClawDetailViewModel.swift")

        #expect(source.contains("ServerStore().load().count"))
        #expect(!source.contains("SessionStore.shared.pairedServers.count"))
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
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client)
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
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client)
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
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client)
        await vm.installClaw(makeClaw("picoclaw", state: .notInstalled, description: "test"))

        #expect(vm.actionError == nil)
    }

    @Test("installClaw sets actionError on HTTP error")
    @MainActor
    func installClaw_setsActionErrorOnHttpError() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockStatusCode = 403
        VMTestURLProtocol.mockResponseData = Data("{\"error\":\"admin access required\"}".utf8)

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client)
        await vm.installClaw(makeClaw("picoclaw", state: .notInstalled, description: "test"))

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
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client)
        await vm.uninstallClaw(makeClaw("picoclaw", description: "test"))

        #expect(vm.actionError == nil)
    }

    // MARK: - Installability gate (theyos #88)

    @Test("store installClaw does NOT call the API for a non-installable claw")
    @MainActor
    func installClaw_nonInstallable_doesNotCallAPI() async {
        VMTestURLProtocol.reset()
        // If the guard fails, the install request flows through the mock and
        // sets capturedRequest — the assertion below catches the regression.
        VMTestURLProtocol.routeOverrides["/install"] = (200, Data("{\"job_id\":\"x\",\"message\":\"m\"}".utf8))
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client)
        let claw = makeClaw(
            "claude-claw",
            state: .notInstalled,
            installable: false,
            unavailableReasonCode: .catalogOnly,
            unavailableReason: "Claude Code plugin, not a server daemon"
        )
        await vm.installClaw(claw)

        #expect(VMTestURLProtocol.capturedRequest == nil, "no HTTP request must be issued for a non-installable claw")
        #expect(vm.actionError != nil)
    }

    @Test("store installClaw DOES call the API for an installable claw")
    @MainActor
    func installClaw_installable_callsAPI() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.routeOverrides["/install"] = (200, Data("{\"job_id\":\"x\",\"message\":\"m\"}".utf8))
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client)
        // installable:true explicitly; also covers the legacy fail-open path
        // since both resolve to .installable.
        await vm.installClaw(makeClaw("openclaw", state: .notInstalled, installable: true))

        #expect(VMTestURLProtocol.capturedRequest != nil, "an installable claw must still issue the install request")
        #expect(vm.actionError == nil)
    }

    @Test("detail installClaw does NOT call the API for a non-installable claw")
    @MainActor
    func detailInstallClaw_nonInstallable_doesNotCallAPI() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.routeOverrides["/install"] = (200, Data("{\"job_id\":\"x\",\"message\":\"m\"}".utf8))
        VMTestURLProtocol.mockResponseData = clawsJSON

        let (client, _) = makeVMTestClient()
        let claw = makeClaw(
            "claude-claw",
            state: .notInstalled,
            installable: false,
            unavailableReasonCode: .catalogOnly,
            unavailableReason: "Claude Code plugin, not a server daemon"
        )
        let vm = ClawDetailViewModel(claw: claw, context: makeTestServerContext(), apiClient: client)
        await vm.installClaw()

        #expect(VMTestURLProtocol.capturedRequest == nil, "no HTTP request must be issued for a non-installable claw")
        #expect(vm.actionError != nil)
        #expect(vm.isPerformingAction == false)
    }

    // MARK: - ClawSetupViewModel

    @Test("loadOptions sets resource defaults from API response")
    @MainActor
    func loadOptions_setsResourceDefaults() async {
        VMTestURLProtocol.reset()
        let host = "load-options.example.test"
        let resourceJSON = Data("""
        {"cpu_cores":{"min":1,"max":10,"default":4},"ram_mb":{"min":1024,"max":12288,"default":3072},"disk_gb":{"min":10,"max":120,"default":25,"disabled":false}}
        """.utf8)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/resource-options")] = (200, resourceJSON)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/users")] = (200, Data("{\"data\":[]}".utf8))
        VMTestURLProtocol.mockResponseData = resourceJSON

        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(
            id: "s-load-options",
            host: host,
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        store.addServer(server, token: "test-token-123")
        store.setActiveServer(id: server.id)
        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: server.id,
            apiClient: client,
            store: store
        )
        vm.serverType = "linux"
        await vm.loadOptions()

        #expect(vm.cpuCores == 4)
        #expect(vm.ramMB == 3072)
        #expect(vm.diskGB == 25)
        #expect(vm.resourceOptions != nil)
        #expect(vm.resourceOptionsWarning == nil)
        #expect(vm.hasLiveResourceLimits == true)
        #expect(vm.showsDiskControl == true)
    }

    @Test("performance profiles apply resource policy from live options")
    @MainActor
    func performanceProfiles_applyLiveResourcePolicy() async {
        VMTestURLProtocol.reset()
        let host = "profile-options.example.test"
        let resourceJSON = Data("""
        {"cpu_cores":{"min":1,"max":10,"default":4},"ram_mb":{"min":1024,"max":12288,"default":3072},"disk_gb":{"min":10,"max":120,"default":25,"disabled":false}}
        """.utf8)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/resource-options")] = (200, resourceJSON)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/users")] = (200, Data("{\"data\":[]}".utf8))
        VMTestURLProtocol.mockResponseData = resourceJSON

        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(
            id: "s-profile-test",
            host: host,
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        store.addServer(server, token: "test-token-123")
        store.setActiveServer(id: server.id)
        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: server.id,
            apiClient: client,
            store: store
        )
        vm.serverType = "linux"

        await vm.loadOptions()
        #expect(vm.performanceProfile == .standard)
        #expect(vm.cpuCores == 4)
        #expect(vm.ramMB == 3072)
        #expect(vm.diskGB == 25)

        vm.selectPerformanceProfile(.efficient)
        #expect(vm.cpuCores == 2)
        #expect(vm.ramMB == 1024)
        #expect(vm.diskGB == 10)

        vm.selectPerformanceProfile(.high)
        #expect(vm.cpuCores == 8)
        #expect(vm.ramMB == 6144)
        #expect(vm.diskGB == 50)
    }

    @Test("manual resource edits switch performance to custom")
    @MainActor
    func manualResourceEdits_switchProfileToCustom() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))
        #expect(vm.performanceProfile == .standard)

        vm.incrementCPU()

        #expect(vm.performanceProfile == .custom)
        vm.selectPerformanceProfile(.standard)
        #expect(vm.performanceProfile == .standard)
        #expect(vm.cpuCores == 2)
        #expect(vm.ramMB == 2048)
        #expect(vm.diskGB == 10)
    }

    @Test("fallback high profile uses safe local defaults")
    @MainActor
    func fallbackHighProfile_usesSafeDefaults() {
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"))

        vm.selectPerformanceProfile(.high)

        #expect(vm.cpuCores == 4)
        #expect(vm.ramMB == 4096)
        #expect(vm.diskGB == 20)
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
        #expect(vm.resourceOptionsWarning?.contains("Safe defaults") == true)
        #expect(vm.cpuCores == 2)
        #expect(vm.ramMB == 2048)
        #expect(vm.diskGB == 10)
        #expect(vm.hasLiveResourceLimits == false)
        #expect(vm.canIncrementCPU == true)
        #expect(vm.canIncrementRAM == true)
        #expect(vm.canIncrementDisk == true)
        #expect(vm.canDecrementCPU == true)
        #expect(vm.canDecrementRAM == true)
        #expect(vm.canDecrementDisk == true)
    }

    @Test("loadOptions failure preserves current resource values")
    @MainActor
    func loadOptions_failurePreservesCurrentResourceValues() async {
        VMTestURLProtocol.reset()
        let host = "resource-failure.example.test"
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/resource-options")] = (500, Data("{\"error\":\"server error\"}".utf8))
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/users")] = (200, Data("{\"data\":[]}".utf8))
        VMTestURLProtocol.mockStatusCode = 500
        VMTestURLProtocol.mockResponseData = Data("{\"error\":\"server error\"}".utf8)

        let (client, _) = makeVMTestClient()
        let vm = ClawSetupViewModel(claw: makeClaw("picoclaw", description: "test"), apiClient: client)
        vm.cpuCores = 7
        vm.ramMB = 12288
        vm.diskGB = 55

        await vm.loadOptions()

        #expect(vm.cpuCores == 7)
        #expect(vm.ramMB == 12288)
        #expect(vm.diskGB == 55)
        #expect(vm.resourceOptions == nil)
        #expect(vm.hasLiveResourceLimits == false)
    }

    @Test("deploy sets deploySucceeded on success")
    @MainActor
    func deploy_setsDeploySucceeded() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = Data("""
        {"id":"inst_xyz","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"active"}
        """.utf8)

        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(
            id: "s-deploy-test",
            host: "test.example.com",
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")

        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: server.id,
            apiClient: client,
            store: store
        )

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
        let vm = ClawDetailViewModel(claw: makeClaw("picoclaw", state: .notInstalled, description: "test"), context: makeTestServerContext(), apiClient: client)
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
        let vm = ClawDetailViewModel(claw: makeClaw("picoclaw", description: "test"), context: makeTestServerContext(), apiClient: client)
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
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client, sleeper: { _ in })
        await vm.loadClaws()

        #expect(vm.isPolling == true)
        #expect(vm.hasTransientClaws == true)
    }

    @Test("polling does not start when all claws ready")
    @MainActor
    func polling_doesNotStartWhenAllReady() async {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = readyClawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client, sleeper: { _ in })
        await vm.loadClaws()

        #expect(vm.isPolling == false)
    }

    @Test("polling stops when all claws become ready")
    @MainActor
    func polling_stopsWhenAllReady() async throws {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(context: makeTestServerContext(), apiClient: client, sleeper: { _ in })
        await vm.loadClaws()
        #expect(vm.isPolling == true)

        // Change mock to return ready — polling loop will pick it up
        VMTestURLProtocol.mockResponseData = readyClawsJSON
        await waitUntil { vm.isPolling == false }

        #expect(vm.isPolling == false)
        #expect(vm.claws.first?.installState.isInstalled == true)
    }

    @Test("polling sends success notification on completion")
    @MainActor
    func polling_sendsSuccessNotification() async throws {
        VMTestURLProtocol.reset()
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        var notifications: [(String, Bool)] = []
        let (client, _) = makeVMTestClient()
        let vm = ClawStoreViewModel(
            context: makeTestServerContext(),
            apiClient: client,
            sleeper: { _ in },
            onInstallComplete: { name, success in notifications.append((name, success)) }
        )
        await vm.loadClaws()

        VMTestURLProtocol.mockResponseData = readyClawsJSON
        await waitUntil { notifications.contains(where: { $0.0 == "picoclaw" && $0.1 == true }) }

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
            context: makeTestServerContext(),
            apiClient: client,
            sleeper: { _ in },
            onInstallComplete: { name, success in notifications.append((name, success)) }
        )
        await vm.loadClaws()

        VMTestURLProtocol.mockResponseData = failedClawsJSON
        await waitUntil { notifications.contains(where: { $0.0 == "picoclaw" && $0.1 == false }) }

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
        // Detail polling hits /availability directly — return the installing projection.
        VMTestURLProtocol.routeOverrides["/availability"] = (200, Data(installingPicoAvailability.utf8))

        let (client, _) = makeVMTestClient()
        let vm = ClawDetailViewModel(
            claw: makeClaw("picoclaw", state: .notInstalled, description: "test"),
            context: makeTestServerContext(),
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
        VMTestURLProtocol.routeOverrides["/availability"] = (200, Data(installingPicoAvailability.utf8))

        var notifications: [(String, Bool)] = []
        let (client, _) = makeVMTestClient()
        let vm = ClawDetailViewModel(
            claw: makeClaw("picoclaw", state: .notInstalled, description: "test"),
            context: makeTestServerContext(),
            apiClient: client,
            sleeper: { _ in },
            onInstallComplete: { name, success in notifications.append((name, success)) }
        )
        await vm.installClaw()
        #expect(vm.isPolling == true)

        // Transition to ready: availability endpoint and catalog both return ready.
        VMTestURLProtocol.routeOverrides["/availability"] = (200, Data(readyPicoAvailability.utf8))
        VMTestURLProtocol.mockResponseData = readyClawsJSON
        await waitUntil { vm.isPolling == false && notifications.contains(where: { $0.0 == "picoclaw" && $0.1 == true }) }

        #expect(vm.isPolling == false)
        #expect(notifications.contains(where: { $0.0 == "picoclaw" && $0.1 == true }))
    }

    @Test("detail polling preserves dedicated availability when catalog lags")
    @MainActor
    func detailPolling_preservesDedicatedAvailabilityWhenCatalogLags() async throws {
        VMTestURLProtocol.reset()
        let installJSON = Data("{\"job_id\":\"job_1\",\"message\":\"install queued\"}".utf8)
        VMTestURLProtocol.routeOverrides["/install"] = (200, installJSON)
        VMTestURLProtocol.routeOverrides["/availability"] = (200, Data(readyPicoAvailability.utf8))
        VMTestURLProtocol.mockResponseData = installingClawsJSON

        var notifications: [(String, Bool)] = []
        let (client, _) = makeVMTestClient()
        let vm = ClawDetailViewModel(
            claw: makeClaw("picoclaw", state: .notInstalled, description: "test"),
            context: makeTestServerContext(),
            apiClient: client,
            sleeper: { _ in },
            onInstallComplete: { name, success in notifications.append((name, success)) }
        )

        await vm.installClaw()
        await waitUntil { vm.isPolling == false && vm.claw.installState.isInstalled }

        #expect(vm.isPolling == false)
        #expect(vm.claw.installState.isInstalled == true)
        #expect(vm.claw.installState.isTransient == false)
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

        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(
            id: "s-monitor-test",
            host: "test.example.com",
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")

        let monitor = ClawDeployMonitor(apiClient: .shared)
        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: server.id,
            apiClient: client,
            store: store,
            deployMonitor: monitor
        )

        await vm.deploy()

        #expect(vm.isDeploying == false)
        #expect(vm.deploySucceeded == true)
        #expect(vm.errorMessage == nil)
        #expect(monitor.activeDeploys.contains(where: { $0.id == "inst_1" }))
    }

    // MARK: - macOS deploy omits disk_gb (Bug #3)

    @Test("deploy with macOS server type omits disk_gb when live limits are unavailable")
    @MainActor
    func deploy_macosOmitsDiskGBWithoutLiveLimits() async {
        VMTestURLProtocol.reset()
        let host = "mac-fallback.example.test"
        let createJSON = Data("""
        {"id":"inst_mac","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"active"}
        """.utf8)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/resource-options")] = (500, Data("{\"error\":\"server down\"}".utf8))
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/users")] = (200, Data("{\"data\":[]}".utf8))
        VMTestURLProtocol.mockResponseData = createJSON

        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(
            id: "s-mac-test",
            host: host,
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: host, expiresAt: "2099-01-01T00:00:00Z")

        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: server.id,
            apiClient: client,
            store: store
        )
        vm.serverType = "macos"
        vm.cpuCores = 8
        vm.ramMB = 16384
        await vm.loadOptions()

        await vm.deploy()

        let request = VMTestURLProtocol.capturedRequest
        if let body = request?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["disk_gb"] == nil, "disk_gb should be omitted for macOS")
            #expect(json["guest_os"] as? String == "macos")
            #expect(json["cpu_cores"] as? Int == 8)
            #expect(json["ram_mb"] as? Int == 16384)
        }
        #expect(vm.hasLiveResourceLimits == false)
    }

    @Test("deploy sends current user-selected values when live limits are unavailable")
    @MainActor
    func deploy_usesCurrentValuesWithoutLiveLimits() async {
        VMTestURLProtocol.reset()
        let host = "linux-fallback.example.test"
        let createJSON = Data("""
        {"id":"inst_linux_fallback","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"active"}
        """.utf8)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/resource-options")] = (500, Data("{\"error\":\"server down\"}".utf8))
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/users")] = (200, Data("{\"data\":[]}".utf8))
        VMTestURLProtocol.mockResponseData = createJSON

        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(
            id: "s-linux-fallback-test",
            host: host,
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: host, expiresAt: "2099-01-01T00:00:00Z")

        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: server.id,
            apiClient: client,
            store: store
        )
        vm.serverType = "linux"
        vm.cpuCores = 9
        vm.ramMB = 14336
        vm.diskGB = 65

        await vm.loadOptions()
        await vm.deploy()

        let request = VMTestURLProtocol.capturedRequest
        if let body = request?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["cpu_cores"] as? Int == 9)
            #expect(json["ram_mb"] as? Int == 14336)
            #expect(json["disk_gb"] as? Int == 65)
            #expect(json["guest_os"] as? String == "linux")
        }
        #expect(vm.hasLiveResourceLimits == false)
    }

    @Test("deploy omits disk_gb when live resource options disable custom disk")
    @MainActor
    func deploy_omitsDiskGBWhenDisabledByResourceOptions() async {
        VMTestURLProtocol.reset()
        let host = "disk-disabled.example.test"
        let resourceJSON = Data("""
        {"cpu_cores":{"min":1,"max":16,"default":6},"ram_mb":{"min":1024,"max":32768,"default":4096},"disk_gb":{"min":20,"max":240,"default":60,"disabled":true}}
        """.utf8)
        let createJSON = Data("""
        {"id":"inst_linux","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"active"}
        """.utf8)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/resource-options")] = (200, resourceJSON)
        VMTestURLProtocol.routeOverrides[vmRoute(host: host, "/users")] = (200, Data("{\"data\":[]}".utf8))
        VMTestURLProtocol.mockResponseData = createJSON

        let store = makeIsolatedSoyehtCoreSessionStore()
        let server = PairedServer(
            id: "s-linux-test",
            host: host,
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        store.addServer(server, token: "test-token-123")
        store.saveSession(token: "test-token-123", host: host, expiresAt: "2099-01-01T00:00:00Z")

        let (client, _) = makeVMTestClient(store: store)
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            initialServerId: server.id,
            apiClient: client,
            store: store
        )
        vm.serverType = "linux"

        await vm.loadOptions()
        await vm.deploy()

        let request = VMTestURLProtocol.capturedRequest
        if let body = request?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["disk_gb"] == nil, "disk_gb should be omitted when disabled by resource-options")
            #expect(json["guest_os"] as? String == "linux")
        }
        #expect(vm.hasLiveResourceLimits == true)
        #expect(vm.showsDiskControl == false)
    }
}

// MARK: - PR-3: ClawSetupViewModel injected `servers:` init
//
// The setup VM's server picker must reflect what the iOS UI computed
// (deployable servers only — Macs without per-Mac tokens absent). The
// VM stays decoupled from `ServerRegistry` because the registry lives
// in the iOS app target; SoyehtCore receives the list as data.

@Suite("ClawSetupViewModel injected servers")
struct ClawSetupViewModelInjectedServersTests {

    private func makeStoreAndServerStore() -> (SessionStore, ServerStore) {
        let suiteName = "com.soyeht.tests.clawsetup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let serverStore = ServerStore(defaults: defaults)
        let store = SessionStore(
            defaults: defaults,
            keychainService: "com.soyeht.tests.clawsetup.\(UUID().uuidString)",
            serverStore: serverStore
        )
        return (store, serverStore)
    }

    @Test("servers reads from the injected list when provided")
    func injected_servers_overrideStorePairedServers() {
        let store = makeIsolatedSoyehtCoreSessionStore()
        // Seed the store with one server that the injected list will
        // intentionally NOT include — proving the init prefers the
        // injected list over `store.pairedServers`.
        let stored = PairedServer(
            id: "stored-only",
            host: "stored.host",
            name: "stored",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux"
        )
        store.addServer(stored, token: "tok-stored")

        let injected = PairedServer(
            id: "injected-only",
            host: "injected.host",
            name: "injected",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux"
        )

        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            servers: [injected],
            store: store
        )

        #expect(vm.servers.count == 1)
        #expect(vm.servers.first?.id == "injected-only")
        #expect(!vm.servers.contains(where: { $0.id == "stored-only" }),
            "Injected `servers:` must shadow `store.pairedServers` — the picker is iOS-computed."
        )
    }

    @Test("default init reads from canonical ServerStore inventory")
    func defaultInit_readsCanonicalServerStoreInventory() {
        let (store, serverStore) = makeStoreAndServerStore()
        let server = PairedServer(
            id: "legacy-server",
            host: "legacy.host",
            name: "legacy",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux"
        )
        store.addServer(server, token: "tok-legacy")
        var canonical = server.toServer()
        canonical.alias = "Canonical Linux"
        canonical.lastHost = "canonical.host"
        serverStore.upsert(canonical)

        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            store: store
        )
        #expect(vm.servers.first?.id == "legacy-server",
            "Default deploy picker should still include servers that have credentials."
        )
        #expect(vm.servers.first?.name == "Canonical Linux",
            "Default deploy picker must render the canonical ServerStore display name, not stale legacy metadata."
        )
        #expect(vm.servers.first?.host == "canonical.host",
            "Default deploy picker must route through the canonical ServerStore host."
        )
    }

    @Test("default init ignores legacy pairedServers that are not in ServerStore")
    func defaultInit_ignoresLegacyRowsMissingFromServerStore() {
        let (store, serverStore) = makeStoreAndServerStore()
        let server = PairedServer(
            id: "legacy-only",
            host: "legacy-only.host",
            name: "legacy only",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux"
        )
        store.addServer(server, token: "tok-legacy-only")
        serverStore.save([])

        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            store: store
        )

        #expect(vm.servers.isEmpty,
            "SessionStore may still hold credentials, but the deploy picker inventory must come from ServerStore."
        )
    }

    @Test("default deploy options enumerate canonical inventory source")
    func defaultDeployOptionsUseCanonicalInventorySource() throws {
        let source = try coreSource("ClawStore/ClawSetupViewModel.swift")
        #expect(source.contains("store.canonicalServers()"))
        #expect(!source.contains("store.pairedServers.compactMap"),
            "The default deploy picker must not enumerate the legacy SessionStore server list directly."
        )
    }

    @Test("initialServerId selects within the injected list")
    func injected_initialServerId_selectsCorrectIndex() {
        let store = makeIsolatedSoyehtCoreSessionStore()
        let s1 = PairedServer(id: "s1", host: "h1", name: "s1", role: "admin", pairedAt: Date(), expiresAt: nil, platform: "linux")
        let s2 = PairedServer(id: "s2", host: "h2", name: "s2", role: "admin", pairedAt: Date(), expiresAt: nil, platform: "linux")

        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            servers: [s1, s2],
            initialServerId: "s2",
            store: store
        )

        #expect(vm.selectedServer?.id == "s2",
            "initialServerId must be resolved against the *injected* list, not store.pairedServers."
        )
    }

    @Test("empty injected list yields no selected server")
    func injected_emptyList_noSelection() {
        let store = makeIsolatedSoyehtCoreSessionStore()
        let vm = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            servers: [],
            store: store
        )
        #expect(vm.servers.isEmpty)
        #expect(vm.canDeploy == false,
            "An empty deployable list must yield canDeploy == false; the View shows the placeholder."
        )
    }

    @Test("deploy calls household-created handler only for household endpoint targets")
    @MainActor
    func deploy_householdCreatedHandlerOnlyForHouseholdEndpoint() async {
        let capture = HouseholdCreatedCapture()
        let mac = PairedServer(
            id: "mac-alpha",
            host: "mac-alpha.test",
            name: "mac-alpha",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos"
        )
        let householdEndpoint = URL(string: "http://mac-alpha.test:8091")!
        let householdOption = ClawDeployOption(
            server: mac,
            target: CreateInstanceTarget.householdEndpoint(householdEndpoint)
        )
        let householdVM = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            deployOptions: [householdOption],
            householdInstanceCreatedHandler: { _, request, response in
                capture.records.append(HouseholdCreatedInstanceRecord(request: request, response: response))
            },
            createInstanceHandler: { request, target in
                guard case .householdEndpoint(let endpoint) = target else {
                    Issue.record("Expected household endpoint target")
                    return CreateInstanceResponse(id: "unexpected", name: request.name, container: "unexpected", clawType: request.clawType, status: .failed, jobId: nil)
                }
                #expect(endpoint == householdEndpoint)
                return CreateInstanceResponse(
                    id: "inst-mac-alpha",
                    name: request.name,
                    container: "picoclaw-mac-alpha",
                    clawType: request.clawType,
                    status: .provisioning,
                    jobId: "job-mac-alpha"
                )
            }
        )

        await householdVM.deploy()

        #expect(capture.records.map(\.id) == ["inst-mac-alpha"])
        #expect(capture.records.first?.clawType == "picoclaw")

        capture.records.removeAll()
        let store = makeIsolatedSoyehtCoreSessionStore()
        let linux = PairedServer(
            id: "linux-alpha",
            host: "linux-alpha.test",
            name: "linux-alpha",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )
        store.addServer(linux, token: "token-linux-alpha")
        guard let context = store.context(for: linux.id) else {
            Issue.record("Expected test context for linux-alpha")
            return
        }
        let serverOption = ClawDeployOption(server: linux, target: .server(context))
        let serverVM = ClawSetupViewModel(
            claw: makeClaw("picoclaw", description: "test"),
            deployOptions: [serverOption],
            store: store,
            householdInstanceCreatedHandler: { _, request, response in
                capture.records.append(HouseholdCreatedInstanceRecord(request: request, response: response))
            },
            createInstanceHandler: { request, target in
                guard case .server = target else {
                    Issue.record("Expected server target")
                    return CreateInstanceResponse(id: "unexpected", name: request.name, container: "unexpected", clawType: request.clawType, status: .failed, jobId: nil)
                }
                return CreateInstanceResponse(
                    id: "inst-linux-alpha",
                    name: request.name,
                    container: "picoclaw-linux-alpha",
                    clawType: request.clawType,
                    status: .active,
                    jobId: "job-linux-alpha"
                )
            }
        )

        await serverVM.deploy()

        #expect(serverVM.deploySucceeded == true)
        #expect(capture.records.isEmpty)
    }
}

@MainActor
private final class HouseholdCreatedCapture {
    var records: [HouseholdCreatedInstanceRecord] = []
}

@Suite("HouseholdCreatedInstancesStore")
struct HouseholdCreatedInstancesStoreTests {
    @Test("round trip, upsert, isolation, prune, and remove")
    func roundTripIsolationPruneAndRemove() {
        let defaults = makeDefaults("HouseholdCreatedInstancesStoreTests")
        let store = HouseholdCreatedInstancesStore(defaults: defaults)

        let first = HouseholdCreatedInstanceRecord(
            id: "inst-alpha",
            name: "alpha workspace",
            container: "alpha-container",
            clawType: "picoclaw"
        )
        let updated = HouseholdCreatedInstanceRecord(
            id: "inst-alpha",
            name: "renamed workspace",
            container: "alpha-container",
            clawType: "picoclaw"
        )
        let second = HouseholdCreatedInstanceRecord(
            id: "inst-beta",
            name: "beta workspace",
            container: "beta-container",
            clawType: "ironclaw"
        )

        store.upsert(first, serverID: "server-alpha")
        store.upsert(second, serverID: "server-beta")
        #expect(store.list(serverID: "server-alpha") == [first])
        #expect(store.list(serverID: "server-beta") == [second])

        let reloaded = HouseholdCreatedInstancesStore(defaults: defaults)
        #expect(reloaded.list(serverID: "server-alpha") == [first])
        #expect(reloaded.list(serverID: "server-beta") == [second])

        reloaded.upsert(updated, serverID: "server-alpha")
        #expect(reloaded.list(serverID: "server-alpha") == [updated])
        #expect(reloaded.list(serverID: "server-beta") == [second])

        reloaded.remove(instanceID: "inst-beta", serverID: "server-beta")
        #expect(reloaded.list(serverID: "server-beta").isEmpty)
    }
}

@Suite("HouseholdCreatedInstancesLoader")
struct HouseholdCreatedInstancesLoaderTests {
    @Test("Mac without context loads household-created status and caches under server id")
    @MainActor
    func macWithoutContextSynthesizesEntry() async {
        let defaults = makeDefaults("HouseholdCreatedInstancesLoaderTests.success")
        let sessionStore = SoyehtCore.SessionStore(
            defaults: defaults,
            keychainService: "HouseholdCreatedInstancesLoaderTests.success.\(UUID().uuidString)"
        )
        let recordStore = HouseholdCreatedInstancesStore(defaults: defaults)
        let server = makeMacServer(id: "mac-alpha")
        recordStore.upsert(
            HouseholdCreatedInstanceRecord(
                id: "inst-alpha",
                name: "alpha workspace",
                container: "alpha-container",
                clawType: "picoclaw"
            ),
            serverID: server.id
        )

        let endpoint = URL(string: "http://mac-alpha.test:8091")!
        let loader = HouseholdCreatedInstancesLoader(
            recordStore: recordStore,
            sessionStore: sessionStore,
            resolver: { target in
                .householdEndpoint(serverID: target.serverID, endpoint: endpoint)
            },
            listFetcher: { _ in
                throw SoyehtAPIClient.APIError.httpError(404, nil)
            },
            statusFetcher: { id, resolvedEndpoint in
                #expect(id == "inst-alpha")
                #expect(resolvedEndpoint == endpoint)
                return InstanceStatusResponse(
                    status: .active,
                    provisioningMessage: "ready",
                    provisioningError: nil,
                    provisioningPhase: "complete"
                )
            }
        )

        let entries = await loader.load(for: [server])

        #expect(entries.count == 1)
        #expect(entries.first?.server.id == server.id)
        #expect(entries.first?.instance.id == "inst-alpha")
        #expect(entries.first?.instance.status == .active)
        #expect(entries.first?.instance.provisioningMessage == "ready")
        #expect(sessionStore.loadInstances(serverId: server.id).map(\.id) == ["inst-alpha"])
    }

    @Test("Mac without context uses household list without local records")
    @MainActor
    func macWithoutContextLoadsHouseholdList() async {
        let defaults = makeDefaults("HouseholdCreatedInstancesLoaderTests.list")
        let sessionStore = SoyehtCore.SessionStore(
            defaults: defaults,
            keychainService: "HouseholdCreatedInstancesLoaderTests.list.\(UUID().uuidString)"
        )
        let recordStore = HouseholdCreatedInstancesStore(defaults: defaults)
        let server = makeMacServer(id: "mac-list")
        let endpoint = URL(string: "http://mac-list.test:8091")!
        let listed = SoyehtInstance(
            id: "inst-listed",
            name: "listed workspace",
            container: "listed-container",
            clawType: "picoclaw",
            fqdn: nil,
            status: .active,
            port: nil,
            capabilities: nil,
            provisioningMessage: "ready",
            provisioningPhase: "complete",
            provisioningError: nil
        )

        let loader = HouseholdCreatedInstancesLoader(
            recordStore: recordStore,
            sessionStore: sessionStore,
            resolver: { target in
                .householdEndpoint(serverID: target.serverID, endpoint: endpoint)
            },
            listFetcher: { resolvedEndpoint in
                #expect(resolvedEndpoint == endpoint)
                return [listed]
            },
            statusFetcher: { _, _ in
                Issue.record("Status fallback should not run for listed instance")
                return InstanceStatusResponse(status: .active, provisioningMessage: nil, provisioningError: nil, provisioningPhase: nil)
            }
        )

        let entries = await loader.load(for: [server])

        #expect(entries.map(\.instance.id) == ["inst-listed"])
        #expect(sessionStore.loadInstances(serverId: server.id).map(\.id) == ["inst-listed"])
        #expect(recordStore.list(serverID: server.id).isEmpty)
        #expect(InstanceListView.terminalUnavailableReason(serverKind: server.kind, hasContext: false) != nil)
    }

    @Test("household list is unioned with local records that still have status")
    @MainActor
    func householdListUnionsWithLocalStatusFallback() async {
        let defaults = makeDefaults("HouseholdCreatedInstancesLoaderTests.union")
        let sessionStore = SoyehtCore.SessionStore(
            defaults: defaults,
            keychainService: "HouseholdCreatedInstancesLoaderTests.union.\(UUID().uuidString)"
        )
        let recordStore = HouseholdCreatedInstancesStore(defaults: defaults)
        let server = makeMacServer(id: "mac-union")
        let endpoint = URL(string: "http://mac-union.test:8091")!
        let listed = SoyehtInstance(
            id: "inst-listed",
            name: "listed workspace",
            container: "listed-container",
            clawType: "picoclaw",
            fqdn: nil,
            status: .active,
            port: nil,
            capabilities: nil,
            provisioningMessage: nil,
            provisioningPhase: nil,
            provisioningError: nil
        )
        recordStore.upsert(
            HouseholdCreatedInstanceRecord(
                id: "inst-local",
                name: "local workspace",
                container: "local-container",
                clawType: "picoclaw"
            ),
            serverID: server.id
        )

        let loader = HouseholdCreatedInstancesLoader(
            recordStore: recordStore,
            sessionStore: sessionStore,
            resolver: { target in
                .householdEndpoint(serverID: target.serverID, endpoint: endpoint)
            },
            listFetcher: { _ in [listed] },
            statusFetcher: { id, _ in
                #expect(id == "inst-local")
                return InstanceStatusResponse(
                    status: .provisioning,
                    provisioningMessage: "starting",
                    provisioningError: nil,
                    provisioningPhase: "starting"
                )
            }
        )

        let entries = await loader.load(for: [server])

        #expect(entries.map(\.instance.id) == ["inst-listed", "inst-local"])
        #expect(entries.last?.instance.status == .provisioning)
        #expect(recordStore.list(serverID: server.id).map(\.id) == ["inst-local"])
        #expect(sessionStore.loadInstances(serverId: server.id).map(\.id) == ["inst-listed", "inst-local"])
    }

    @Test("404 prunes household-created record and clears server cache")
    @MainActor
    func notFoundPrunesRecord() async {
        let defaults = makeDefaults("HouseholdCreatedInstancesLoaderTests.notFound")
        let sessionStore = SoyehtCore.SessionStore(
            defaults: defaults,
            keychainService: "HouseholdCreatedInstancesLoaderTests.notFound.\(UUID().uuidString)"
        )
        let recordStore = HouseholdCreatedInstancesStore(defaults: defaults)
        let server = makeMacServer(id: "mac-beta")
        let cached = SoyehtInstance(
            id: "inst-missing",
            name: "missing workspace",
            container: "missing-container",
            clawType: "picoclaw",
            fqdn: nil,
            status: .active,
            port: nil,
            capabilities: nil,
            provisioningMessage: nil,
            provisioningPhase: nil,
            provisioningError: nil
        )
        sessionStore.saveInstances([cached], serverId: server.id)
        recordStore.upsert(
            HouseholdCreatedInstanceRecord(
                id: "inst-missing",
                name: "missing workspace",
                container: "missing-container",
                clawType: "picoclaw"
            ),
            serverID: server.id
        )

        let loader = HouseholdCreatedInstancesLoader(
            recordStore: recordStore,
            sessionStore: sessionStore,
            resolver: { target in
                .householdEndpoint(
                    serverID: target.serverID,
                    endpoint: URL(string: "http://mac-beta.test:8091")!
                )
            },
            listFetcher: { _ in
                throw SoyehtAPIClient.APIError.httpError(404, nil)
            },
            statusFetcher: { _, _ in
                throw SoyehtAPIClient.APIError.httpError(404, nil)
            }
        )

        let entries = await loader.load(for: [server])

        #expect(entries.isEmpty)
        #expect(recordStore.list(serverID: server.id).isEmpty)
        #expect(sessionStore.loadInstances(serverId: server.id).isEmpty)
    }

    @Test("transient status error keeps cached household-created line")
    @MainActor
    func transientStatusErrorKeepsCachedRecordAndCache() async {
        let defaults = makeDefaults("HouseholdCreatedInstancesLoaderTests.transient")
        let sessionStore = SoyehtCore.SessionStore(
            defaults: defaults,
            keychainService: "HouseholdCreatedInstancesLoaderTests.transient.\(UUID().uuidString)"
        )
        let recordStore = HouseholdCreatedInstancesStore(defaults: defaults)
        let server = makeMacServer(id: "mac-delta")
        let cached = SoyehtInstance(
            id: "inst-delta",
            name: "delta workspace",
            container: "delta-container",
            clawType: "picoclaw",
            fqdn: nil,
            status: .active,
            port: nil,
            capabilities: nil,
            provisioningMessage: nil,
            provisioningPhase: nil,
            provisioningError: nil
        )
        sessionStore.saveInstances([cached], serverId: server.id)
        recordStore.upsert(
            HouseholdCreatedInstanceRecord(
                id: "inst-delta",
                name: "delta workspace",
                container: "delta-container",
                clawType: "picoclaw"
            ),
            serverID: server.id
        )

        let loader = HouseholdCreatedInstancesLoader(
            recordStore: recordStore,
            sessionStore: sessionStore,
            resolver: { target in
                .householdEndpoint(
                    serverID: target.serverID,
                    endpoint: URL(string: "http://mac-delta.test:8091")!
                )
            },
            listFetcher: { _ in
                throw SoyehtAPIClient.APIError.httpError(404, nil)
            },
            statusFetcher: { _, _ in
                throw SoyehtAPIClient.APIError.httpError(500, nil)
            }
        )

        let entries = await loader.load(for: [server])

        #expect(entries.map(\.instance.id) == ["inst-delta"])
        #expect(recordStore.list(serverID: server.id).map(\.id) == ["inst-delta"])
        #expect(sessionStore.loadInstances(serverId: server.id).map(\.id) == ["inst-delta"])
    }

    @Test("transient household list error keeps cached line without local records")
    @MainActor
    func transientListErrorKeepsCachedInstances() async {
        let defaults = makeDefaults("HouseholdCreatedInstancesLoaderTests.listTransient")
        let sessionStore = SoyehtCore.SessionStore(
            defaults: defaults,
            keychainService: "HouseholdCreatedInstancesLoaderTests.listTransient.\(UUID().uuidString)"
        )
        let recordStore = HouseholdCreatedInstancesStore(defaults: defaults)
        let server = makeMacServer(id: "mac-list-transient")
        let cached = SoyehtInstance(
            id: "inst-cached",
            name: "cached workspace",
            container: "cached-container",
            clawType: "picoclaw",
            fqdn: nil,
            status: .active,
            port: nil,
            capabilities: nil,
            provisioningMessage: nil,
            provisioningPhase: nil,
            provisioningError: nil
        )
        sessionStore.saveInstances([cached], serverId: server.id)

        let loader = HouseholdCreatedInstancesLoader(
            recordStore: recordStore,
            sessionStore: sessionStore,
            resolver: { target in
                .householdEndpoint(
                    serverID: target.serverID,
                    endpoint: URL(string: "http://mac-list-transient.test:8091")!
                )
            },
            listFetcher: { _ in
                throw SoyehtAPIClient.APIError.httpError(500, nil)
            },
            statusFetcher: { _, _ in
                Issue.record("No local records should require status fallback")
                return InstanceStatusResponse(status: .active, provisioningMessage: nil, provisioningError: nil, provisioningPhase: nil)
            }
        )

        let entries = await loader.load(for: [server])

        #expect(entries.map(\.instance.id) == ["inst-cached"])
        #expect(recordStore.list(serverID: server.id).isEmpty)
        #expect(sessionStore.loadInstances(serverId: server.id).map(\.id) == ["inst-cached"])
    }

    @Test("Mac with ServerContext skips household-created loader")
    @MainActor
    func macWithContextSkipsHouseholdCreatedLoader() async {
        let defaults = makeDefaults("HouseholdCreatedInstancesLoaderTests.context")
        let sessionStore = SoyehtCore.SessionStore(
            defaults: defaults,
            keychainService: "HouseholdCreatedInstancesLoaderTests.context.\(UUID().uuidString)"
        )
        let recordStore = HouseholdCreatedInstancesStore(defaults: defaults)
        let server = makeMacServer(id: "mac-gamma")
        recordStore.upsert(
            HouseholdCreatedInstanceRecord(
                id: "inst-gamma",
                name: "gamma workspace",
                container: "gamma-container",
                clawType: "picoclaw"
            ),
            serverID: server.id
        )
        sessionStore.addServer(
            PairedServer(
                id: server.id,
                host: "mac-gamma.test",
                name: "mac-gamma",
                role: "admin",
                pairedAt: Date(),
                expiresAt: nil,
                platform: "macos",
                kind: .engine
            ),
            token: "token-mac-gamma"
        )

        let loader = HouseholdCreatedInstancesLoader(
            recordStore: recordStore,
            sessionStore: sessionStore,
            resolver: { _ in
                Issue.record("Resolver should not be called for a server with context")
                return .unavailable(.missingContext)
            },
            statusFetcher: { _, _ in
                Issue.record("Status fetcher should not be called for a server with context")
                return InstanceStatusResponse(status: .active, provisioningMessage: nil, provisioningError: nil, provisioningPhase: nil)
            }
        )

        let entries = await loader.load(for: [server])

        #expect(entries.isEmpty)
        #expect(recordStore.list(serverID: server.id).map(\.id) == ["inst-gamma"])
    }
}

private func makeDefaults(_ prefix: String) -> UserDefaults {
    let suiteName = "\(prefix).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func makeMacServer(id: String) -> Server {
    Server(
        id: id,
        kind: .mac,
        pairedAt: Date(),
        lastSeenAt: Date(),
        alias: nil,
        hostname: "\(id).test",
        lastHost: "\(id).test"
    )
}

private func coreSource(_ relativePath: String) throws -> String {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SoyehtTests/
        .deletingLastPathComponent()  // TerminalApp/
        .deletingLastPathComponent()  // repo root
    let url = repoRoot
        .appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore")
        .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}
