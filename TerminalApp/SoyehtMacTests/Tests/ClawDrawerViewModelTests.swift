import SoyehtCore
import XCTest

@testable import SoyehtMacDomain

@MainActor
final class ClawDrawerViewModelTests: XCTestCase {
    func test_refresh_supersededLoadDoesNotPublishStaleRows() async {
        let store = makeStore(activeServerID: "srv", host: "api1.example.test", name: "first")
        let staleGate = Gate()
        var buildCount = 0
        let viewModel = ClawDrawerViewModel(
            sessionStore: store,
            makeService: { target in
                buildCount += 1
                switch buildCount {
                case 1:
                    return ClawInventoryService(
                        target: target,
                        fetchClaws: { _ in
                            await staleGate.arriveAndWait()
                            return [self.claw("stale")]
                        },
                        fetchInstances: { _ in [self.instance("stale", name: "stale-row", online: true)] },
                        autoPoll: false
                    )
                default:
                    return ClawInventoryService(
                        target: target,
                        fetchClaws: { _ in [self.claw("fresh")] },
                        fetchInstances: { _ in [self.instance("fresh", name: "fresh-row", online: true)] },
                        autoPoll: false
                    )
                }
            }
        )

        viewModel.refresh()
        XCTAssertTrue(viewModel.isLoading)

        replaceActiveServer(in: store, id: "srv", host: "api2.example.test", name: "second")
        viewModel.refresh()
        await waitUntil { viewModel.rows.map(\.title) == ["fresh-row"] && !viewModel.isLoading }

        await staleGate.open()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.rows.map(\.title), ["fresh-row"])
        XCTAssertEqual(viewModel.context?.host, "api2.example.test")
    }

    func test_refresh_rebuildsServiceWhenContextChangesForSameServerId() async {
        let store = makeStore(activeServerID: "srv", host: "api1.example.test", name: "first")
        var builtHosts: [String] = []
        let viewModel = ClawDrawerViewModel(
            sessionStore: store,
            makeService: { target in
                builtHosts.append(self.host(from: target))
                return ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in [] },
                    fetchInstances: { _ in [] },
                    autoPoll: false
                )
            }
        )

        viewModel.refresh()
        await waitUntil { builtHosts == ["api1.example.test"] && !viewModel.isLoading }

        replaceActiveServer(in: store, id: "srv", host: "api2.example.test", name: "second")
        viewModel.refresh()
        await waitUntil { builtHosts == ["api1.example.test", "api2.example.test"] && !viewModel.isLoading }

        XCTAssertEqual(viewModel.context?.host, "api2.example.test")
    }

    func test_refreshErrorFallsBackToCachedRows() async {
        let store = makeStore(activeServerID: "srv", host: "api.example.test", name: "device-alpha")
        store.saveInstances(
            [instance("cached", name: "cached-row", online: true)],
            serverId: "srv"
        )

        let viewModel = ClawDrawerViewModel(
            sessionStore: store,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in [self.claw("cached")] },
                    fetchInstances: { _ in throw TestError() },
                    autoPoll: false
                )
            }
        )

        viewModel.refresh()
        await waitUntil { viewModel.errorMessage != nil && viewModel.rows.map(\.title) == ["cached-row"] }

        XCTAssertEqual(viewModel.rows.first?.subtitle, "device-alpha")
        XCTAssertEqual(viewModel.rows.first?.status, .online)
        XCTAssertEqual(viewModel.catalogClaws.map(\.name), ["cached"])
    }

    func test_installNonInstallableClawSetsActionErrorWithoutStartingInstall() async {
        let store = makeStore(activeServerID: "srv", host: "api.example.test", name: "device-alpha")
        let viewModel = ClawDrawerViewModel(
            sessionStore: store,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in [] },
                    fetchInstances: { _ in [] },
                    autoPoll: false
                )
            }
        )

        viewModel.refresh()
        await waitUntil { viewModel.context != nil && !viewModel.isLoading }

        viewModel.install(
            claw(
                "catalog-only",
                installed: false,
                installable: false,
                unavailableReason: "Not offered by this server"
            ),
            readiness: .allowed(.ready)
        )

        XCTAssertEqual(viewModel.actionError, "Not offered by this server")
        XCTAssertTrue(viewModel.installingClaws.isEmpty)
    }

    func test_installSuccessRefreshesLocallyWithoutImmediateInstalledSetNotification() async {
        let store = makeStore(activeServerID: "srv", host: "api.example.test", name: "device-alpha")
        let notifications = NotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.installedSetChanged,
            object: nil,
            queue: nil
        ) { _ in
            notifications.record()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var installRequests: [(name: String, host: String)] = []
        var refreshCount = 0
        let viewModel = ClawDrawerViewModel(
            sessionStore: store,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in
                        refreshCount += 1
                        return [self.claw("installable", installed: false)]
                    },
                    fetchInstances: { _ in [] },
                    autoPoll: false
                )
            },
            performInstall: { name, context in
                installRequests.append((name: name, host: context.host))
                return SoyehtAPIClient.ClawActionResponse(jobId: "job-1", message: "queued")
            }
        )

        viewModel.refresh()
        await waitUntil { refreshCount == 1 && !viewModel.isLoading }

        viewModel.install(
            claw("installable", installed: false),
            readiness: .allowed(.ready)
        )
        await waitUntil {
            installRequests.count == 1 &&
            refreshCount >= 2 &&
            viewModel.installingClaws.isEmpty
        }

        XCTAssertEqual(installRequests.map(\.name), ["installable"])
        XCTAssertEqual(installRequests.first?.host, "api.example.test")
        XCTAssertNil(viewModel.actionError)
        XCTAssertEqual(notifications.count, 0, "POST success must not publish the global installed-set notification")
    }

    // MARK: - Helpers

    private func makeStore(activeServerID: String, host: String, name: String) -> SessionStore {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.soyeht.tests.drawer-vm.\(id)")!
        defaults.removePersistentDomain(forName: "com.soyeht.tests.drawer-vm.\(id)")
        let store = SessionStore(defaults: defaults, keychainService: "com.soyeht.tests.drawer-vm.\(id)")
        replaceActiveServer(in: store, id: activeServerID, host: host, name: name)
        return store
    }

    private func replaceActiveServer(in store: SessionStore, id: String, host: String, name: String) {
        let server = PairedServer(
            id: id,
            host: host,
            name: name,
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        store.addServer(server, token: "token-\(host)")
        store.setActiveServer(id: id)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }

    private func host(from target: ClawMachineTarget) -> String {
        guard case .server(let context) = target else {
            return "<unexpected>"
        }
        return context.host
    }

    private func claw(
        _ name: String,
        installed: Bool = true,
        installable: Bool? = true,
        unavailableReason: String? = nil
    ) -> Claw {
        let status: InstallStatus = installed ? .succeeded : .notInstalled
        let overall: OverallState = installed ? .creatable : .notInstalled
        return Claw(
            name: name,
            description: "test claw",
            language: "swift",
            buildable: true,
            version: nil,
            binarySizeMb: nil,
            minRamMb: nil,
            license: nil,
            updatedAt: nil,
            availability: ClawAvailability(
                name: name,
                install: InstallProjection(status: status, progress: nil, installedAt: nil, error: nil, jobId: nil),
                host: HostProjection(coldPathReady: true, hasGolden: true, hasBaseRootfs: true, maintenanceBlocked: false, maintenanceRetryAfterSecs: nil),
                overall: overall,
                reasons: [],
                degradations: []
            ),
            installable: installable,
            unavailableReasonCode: installable == false ? .catalogOnly : nil,
            unavailableReason: unavailableReason
        )
    }

    private func instance(_ clawType: String, name: String, online: Bool) -> SoyehtInstance {
        SoyehtInstance(
            id: "instance-\(clawType)",
            name: name,
            container: "container-\(clawType)",
            clawType: clawType,
            fqdn: nil,
            status: online ? .active : .stopped,
            port: nil,
            capabilities: nil,
            provisioningMessage: nil,
            provisioningPhase: nil,
            provisioningError: nil
        )
    }
}

private struct TestError: Error {}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private actor Gate {
    private var opened = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        if opened { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func open() {
        opened = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}
