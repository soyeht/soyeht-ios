import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

/// E2d-2: proves `InstalledClawsProvider` now delegates its fetch + online-filter
/// to the shared `ClawInventoryService` and republishes
/// `snapshot.deployedOnlineClaws`. Uses an injected service with fake fetchers —
/// no network, no URLProtocol — so it runs deterministically.
@MainActor
final class InstalledClawsProviderServiceAdoptionTests: XCTestCase {

    func test_provider_publishesDeployedOnlineClawsFromService() async {
        let store = makeStore(activeServerID: "srv")

        let provider = InstalledClawsProvider(
            sessionStore: store,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in [
                        self.claw("Zeta", installed: true),
                        self.claw("alpha", installed: true),
                        self.claw("beta", installed: false),   // not installed
                    ] },
                    fetchInstances: { _ in [
                        self.instance("Zeta", online: true),
                        self.instance("alpha", online: true),
                        self.instance("beta", online: true),
                    ] },
                    autoPoll: false
                )
            }
        )

        provider.refresh()
        await waitUntil { provider.hasLoaded }

        // Deployed = installed AND online, name-sorted case-insensitively.
        XCTAssertEqual(provider.claws.map(\.name), ["alpha", "Zeta"])
        XCTAssertEqual(provider.agentOrder, [.shell, .claw("alpha"), .claw("Zeta")])
    }

    func test_provider_excludesInstalledClawWithoutOnlineInstance() async {
        let store = makeStore(activeServerID: "srv")
        let provider = InstalledClawsProvider(
            sessionStore: store,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in [self.claw("alpha", installed: true)] },
                    fetchInstances: { _ in [self.instance("alpha", online: false)] },
                    autoPoll: false
                )
            }
        )
        provider.refresh()
        await waitUntil { provider.hasLoaded }
        XCTAssertEqual(provider.claws, [], "Installed but offline → not surfaced in the picker")
    }

    func test_provider_noActiveServer_fallsBackToCanonical() async {
        let store = makeStore(activeServerID: nil)
        let provider = InstalledClawsProvider(
            sessionStore: store,
            makeService: { target in
                ClawInventoryService(target: target, fetchClaws: { _ in [] }, fetchInstances: { _ in [] }, autoPoll: false)
            }
        )
        provider.refresh()
        await waitUntil { provider.hasLoaded }
        XCTAssertEqual(provider.claws, [])
        XCTAssertEqual(provider.agentOrder, [.shell])
    }

    /// Review fix 1: the same server id changing host/token must rebuild the
    /// pinned service (the cache key is the full context, not just the id).
    func test_provider_rebuildsServiceWhenContextChangesForSameServerId() async {
        let store = makeStore(activeServerID: "srv")
        var builtCount = 0
        let provider = InstalledClawsProvider(
            sessionStore: store,
            makeService: { target in
                builtCount += 1
                return ClawInventoryService(target: target, fetchClaws: { _ in [] }, fetchInstances: { _ in [] }, autoPoll: false)
            }
        )
        provider.refresh()
        await waitUntil { provider.hasLoaded }
        XCTAssertEqual(builtCount, 1)

        // Same id, new host/token → currentContext() differs → service rebuilt.
        _ = store.addServer(
            PairedServer(id: "srv", host: "api2.example.test", name: "t2", role: "admin", pairedAt: Date(), expiresAt: nil),
            token: "tok2"
        )
        store.setActiveServer(id: "srv")

        provider.refresh()
        await waitUntil { builtCount == 2 }
        XCTAssertEqual(builtCount, 2, "Same server id with a changed context must rebuild the pinned service")
    }

    /// Review fix 2: a load is in flight (isLoading == true), the active server
    /// goes away, and `activeServerChanged` cancels + re-refreshes into the
    /// no-context path. That path must clear `isLoading` (the bug left it stuck).
    func test_provider_noContextAfterInFlightLoad_clearsIsLoading() async {
        let store = makeStore(activeServerID: "srv")
        let gate = Gate()
        let provider = InstalledClawsProvider(
            sessionStore: store,
            makeService: { target in
                ClawInventoryService(
                    target: target,
                    fetchClaws: { _ in await gate.arriveAndWait(); return [] },  // gated → load stays in flight
                    fetchInstances: { _ in [] },
                    autoPoll: false
                )
            }
        )

        provider.refresh()
        await waitUntil { provider.isLoading }     // load in flight (gated)

        // Active server disappears while the load is in flight; the observer
        // cancels it and re-refreshes into the no-context path.
        store.activeServerId = nil
        NotificationCenter.default.post(name: ClawStoreNotifications.activeServerChanged, object: nil)

        await waitUntil { provider.hasLoaded && !provider.isLoading }
        await gate.open()  // release the abandoned fetch

        XCTAssertFalse(provider.isLoading, "No-context path after an in-flight load must clear isLoading")
        XCTAssertEqual(provider.claws, [])
    }

    // MARK: - Helpers

    private func makeStore(activeServerID: String?) -> SessionStore {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.soyeht.tests.provider-adopt.\(id)")!
        defaults.removePersistentDomain(forName: "com.soyeht.tests.provider-adopt.\(id)")
        let store = SessionStore(defaults: defaults, keychainService: "com.soyeht.tests.provider-adopt.\(id)")
        if let activeServerID {
            let server = PairedServer(
                id: activeServerID, host: "api.example.test", name: "t",
                role: "admin", pairedAt: Date(), expiresAt: nil
            )
            store.addServer(server, token: "tok")
            store.setActiveServer(id: server.id)
        }
        return store
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }

    private func claw(_ name: String, installed: Bool) -> Claw {
        let status: InstallStatus = installed ? .succeeded : .notInstalled
        let overall: OverallState = installed ? .creatable : .notInstalled
        return Claw(
            name: name, description: "d", language: "rust", buildable: true,
            version: nil, binarySizeMb: nil, minRamMb: nil, license: nil, updatedAt: nil,
            availability: ClawAvailability(
                name: name,
                install: InstallProjection(status: status, progress: nil, installedAt: nil, error: nil, jobId: nil),
                host: HostProjection(coldPathReady: true, hasGolden: true, hasBaseRootfs: true, maintenanceBlocked: false, maintenanceRetryAfterSecs: nil),
                overall: overall, reasons: [], degradations: []
            ),
            installable: true
        )
    }

    private func instance(_ clawType: String, online: Bool) -> SoyehtInstance {
        SoyehtInstance(
            id: "i-\(clawType)", name: clawType, container: "c-\(clawType)",
            clawType: clawType, fqdn: nil, status: online ? .active : .stopped,
            port: nil, capabilities: nil,
            provisioningMessage: nil, provisioningPhase: nil, provisioningError: nil
        )
    }
}

/// A one-shot gate that lets a test hold a fetch open (so a load stays in flight)
/// and signals when the gated fetch has arrived.
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
