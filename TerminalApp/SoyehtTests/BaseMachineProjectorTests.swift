import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

@MainActor
final class BaseMachineProjectorTests: XCTestCase {
    func testRefreshProjectsValidatedSelfMachineInMemoryWithoutPairingRouteOrSecret() async throws {
        let householdID = "hh_projector_example"
        let machineID = try MachineID(
            authenticatedMachinePublicKey: try machineKey(seed: 0x22)
                .publicKey.compressedRepresentation
        )
        let snapshot = try machinesSnapshot(
            householdID: householdID,
            machineID: machineID,
            hostLabel: "mac-alpha"
        )
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }

        let ownerKey = try machineKey(seed: 0x33)
        let projector = BaseMachineProjector(
            authorityBootstrapper: StubAuthorityBootstrapper(snapshot: snapshot),
            keyProvider: StubOwnerIdentityKeyProvider(privateKey: ownerKey),
            registry: registryFixture.registry,
            activeHousehold: { try! self.householdState(id: householdID, ownerKey: ownerKey) },
            canReadMachineInventory: { _ in true }
        )

        await projector.refresh()

        let projected = try XCTUnwrap(registryFixture.registry.baseMachines.only)
        XCTAssertEqual(projected.engineMachineId, machineID.rawValue)
        XCTAssertEqual(projected.hostname, "mac-alpha")
        XCTAssertEqual(projected.id, BaseMachineProjector.stableServerID(for: machineID).uuidString)
        XCTAssertNil(projected.lastHost, "Slice 2 must not infer a route from identity inventory")
        XCTAssertNil(projected.presencePort)
        XCTAssertNil(projected.attachPort)
        XCTAssertNil(registryFixture.registry.pairedMac(for: projected.id),
            "The base-machine projection must never masquerade as a legacy HMAC pairing")
        XCTAssertTrue(registryFixture.registry.operationalServers.isEmpty,
            "Identity-only projection must not enter operation/Claw routing lists before presence")
        XCTAssertFalse(registryFixture.store.load().contains(where: { $0.id == projected.id }),
            "Projection is reconstructed from owner-authenticated inventory, never persisted as a paired server")
    }

    func testBaseProjectionAloneChoosesHouseholdHomeWithoutOperationalRecoverySideEffects() throws {
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }
        let ownerKey = try machineKey(seed: 0x33)
        let household = try householdState(id: "hh_recovery", ownerKey: ownerKey)
        let machineID = try machineID(seed: 0x22)

        registryFixture.registry.projectBaseMachine(
            householdID: household.householdId,
            serverID: BaseMachineProjector.stableServerID(for: machineID),
            machineID: machineID,
            hostLabel: "mac-alpha",
            joinedAt: 1_725_000_000
        )

        XCTAssertEqual(
            HouseholdRecoveryDestination.resolve(registry: registryFixture.registry),
            .householdHome,
            "A valid household with only the display-only base must not enter instance recovery."
        )
        XCTAssertEqual(
            HomeFallbackDestination.resolve(
                registry: registryFixture.registry,
                hasActiveHousehold: true
            ),
            .householdHome,
            "Return/cancel fallbacks must keep a base-only household out of the instance list."
        )
        XCTAssertFalse(registryFixture.registry.servers.isEmpty)
        XCTAssertTrue(registryFixture.registry.operationalServers.isEmpty)
        XCTAssertTrue(registryFixture.store.load().isEmpty,
            "The base display projection must not create a persisted operational server row.")
    }

    func testBaseProjectionDoesNotFlipColdLaunchSetupState() throws {
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }
        let machineID = try machineID(seed: 0x22)

        registryFixture.registry.projectBaseMachine(
            householdID: "hh_cold_launch",
            serverID: BaseMachineProjector.stableServerID(for: machineID),
            machineID: machineID,
            hostLabel: "mac-alpha",
            joinedAt: 1_725_000_000
        )

        XCTAssertFalse(registryFixture.registry.servers.isEmpty)
        XCTAssertTrue(registryFixture.registry.operationalServers.isEmpty)
        XCTAssertFalse(
            SceneDelegate.hasAnySetupState(
                operationalServerCount: registryFixture.registry.operationalServers.count,
                identityIsActive: false
            ),
            "A base-only display projection must not suppress cold-launch install discovery."
        )
        XCTAssertTrue(
            SceneDelegate.hasAnySetupState(
                operationalServerCount: registryFixture.registry.operationalServers.count,
                identityIsActive: true
            ),
            "An active household remains setup state independently of the display projection."
        )
    }

    func testRefreshRejectsSnapshotForDifferentActiveHousehold() async throws {
        let machineID = try MachineID(
            authenticatedMachinePublicKey: try machineKey(seed: 0x22)
                .publicKey.compressedRepresentation
        )
        let snapshot = try machinesSnapshot(
            householdID: "hh_other",
            machineID: machineID,
            hostLabel: "mac-alpha"
        )
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }

        let ownerKey = try machineKey(seed: 0x33)
        let projector = BaseMachineProjector(
            authorityBootstrapper: StubAuthorityBootstrapper(snapshot: snapshot),
            keyProvider: StubOwnerIdentityKeyProvider(privateKey: ownerKey),
            registry: registryFixture.registry,
            activeHousehold: { try! self.householdState(id: "hh_expected", ownerKey: ownerKey) },
            canReadMachineInventory: { _ in true }
        )

        await projector.refresh()

        XCTAssertTrue(registryFixture.registry.baseMachines.isEmpty)
    }

    func testNoActiveHouseholdClearsOnlyTheEphemeralProjection() async throws {
        let machineID = try MachineID(
            authenticatedMachinePublicKey: try machineKey(seed: 0x22)
                .publicKey.compressedRepresentation
        )
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }
        registryFixture.registry.projectBaseMachine(
            householdID: "hh_projector_example",
            serverID: BaseMachineProjector.stableServerID(for: machineID),
            machineID: machineID,
            hostLabel: "mac-alpha",
            joinedAt: 1_725_000_000
        )

        let projector = BaseMachineProjector(
            authorityBootstrapper: FailingAuthorityBootstrapper(),
            keyProvider: StubOwnerIdentityKeyProvider(privateKey: try machineKey(seed: 0x33)),
            registry: registryFixture.registry,
            activeHousehold: { nil },
            canReadMachineInventory: { _ in true }
        )

        await projector.refresh()

        XCTAssertTrue(registryFixture.registry.baseMachines.isEmpty)
        XCTAssertTrue(registryFixture.store.load().isEmpty)
    }

    func testIdentityOnlyBaseMachineCannotResolveOrPersistOperationalState() throws {
        let householdID = "hh_projector_example"
        let machineID = try MachineID(
            authenticatedMachinePublicKey: try machineKey(seed: 0x22)
                .publicKey.compressedRepresentation
        )
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }
        let serverID = BaseMachineProjector.stableServerID(for: machineID)
        registryFixture.registry.projectBaseMachine(
            householdID: householdID,
            serverID: serverID,
            machineID: machineID,
            hostLabel: "mac-alpha",
            joinedAt: 1_725_000_000
        )
        let isolatedSessionStore = SessionStore(
            defaults: registryFixture.defaults,
            keychainService: "com.soyeht.tests.base-machine.\(UUID().uuidString)",
            serverStore: registryFixture.store
        )

        let resolution = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: serverID.uuidString),
            registry: registryFixture.registry,
            sessionStore: isolatedSessionStore,
            localNetworkActive: true,
            tailnetActive: true
        )

        XCTAssertEqual(resolution, .unavailable(.missingContext),
            "An identity-only base machine is display-only, even when its label resembles a usable host."
        )
        XCTAssertEqual(registryFixture.registry.baseMachines.only?.id, serverID.uuidString,
            "Blocking operation routing must not remove the visible owned-machine row."
        )

        registryFixture.registry.updateTheyOSStatus(
            serverID: serverID.uuidString,
            status: .running,
            version: "example"
        )
        XCTAssertTrue(registryFixture.store.load().isEmpty,
            "Status updates must never persist an identity-only projection into ServerStore."
        )
    }

    func testRefreshClearsPriorHouseholdProjectionBeforeFailedBootstrap() async throws {
        let priorMachineID = try MachineID(
            authenticatedMachinePublicKey: try machineKey(seed: 0x22)
                .publicKey.compressedRepresentation
        )
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }
        registryFixture.registry.projectBaseMachine(
            householdID: "hh_prior",
            serverID: BaseMachineProjector.stableServerID(for: priorMachineID),
            machineID: priorMachineID,
            hostLabel: "mac-alpha",
            joinedAt: 1_725_000_000
        )
        let ownerKey = try machineKey(seed: 0x33)
        let activeState = try householdState(id: "hh_current", ownerKey: ownerKey)
        let projector = BaseMachineProjector(
            authorityBootstrapper: FailingAuthorityBootstrapper(),
            keyProvider: StubOwnerIdentityKeyProvider(privateKey: ownerKey),
            registry: registryFixture.registry,
            activeHousehold: { activeState },
            canReadMachineInventory: { _ in true }
        )

        await projector.refresh()

        XCTAssertTrue(registryFixture.registry.baseMachines.isEmpty,
            "A failed current-household bootstrap must not leave another household's base machine visible."
        )
    }

    func testRefreshHasZeroProjectionSideEffectWhenHouseholdChangesDuringBootstrap() async throws {
        let ownerKey = try machineKey(seed: 0x33)
        let initialState = try householdState(id: "hh_initial", ownerKey: ownerKey)
        let switchedState = try householdState(id: "hh_switched", ownerKey: ownerKey)
        let activeHousehold = ActiveHouseholdBox(initialState)
        let machineID = try MachineID(
            authenticatedMachinePublicKey: try machineKey(seed: 0x22)
                .publicKey.compressedRepresentation
        )
        let snapshot = try machinesSnapshot(
            householdID: initialState.householdId,
            machineID: machineID,
            hostLabel: "mac-alpha"
        )
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }
        let projector = BaseMachineProjector(
            authorityBootstrapper: SwitchingAuthorityBootstrapper(snapshot: snapshot) {
                activeHousehold.value = switchedState
            },
            keyProvider: StubOwnerIdentityKeyProvider(privateKey: ownerKey),
            registry: registryFixture.registry,
            activeHousehold: { activeHousehold.value },
            canReadMachineInventory: { _ in true }
        )

        await projector.refresh()

        XCTAssertTrue(registryFixture.registry.baseMachines.isEmpty,
            "An A → B switch while /machines is awaited must not project A into B's home."
        )
    }

    func testWrongHouseholdBootstrapLeavesProjectionAndServerStoreUntouched() async throws {
        let ownerKey = try machineKey(seed: 0x33)
        let activeHousehold = try householdState(id: "hh_current", ownerKey: ownerKey)
        let machineID = try machineID(seed: 0x22)
        let body = try rawMachinesResponse(
            householdID: "hh_other",
            selfMachineID: machineID.rawValue,
            machines: [rawMachine(machineID: machineID, publicKey: machineID.machinePublicKey, isSelf: true)]
        )

        try await assertRejectedRawInventoryLeavesStateUntouched(
            body: body,
            activeHousehold: activeHousehold,
            ownerKey: ownerKey,
            expectedError: .householdIDMismatch(expected: "hh_current", actual: "hh_other")
        )
    }

    func testWrongRespondentBootstrapLeavesProjectionAndServerStoreUntouched() async throws {
        let ownerKey = try machineKey(seed: 0x33)
        let activeHousehold = try householdState(id: "hh_current", ownerKey: ownerKey)
        let selfMachineID = try machineID(seed: 0x22)
        let reportedMachineID = try machineID(seed: 0x23)
        let body = try rawMachinesResponse(
            householdID: activeHousehold.householdId,
            selfMachineID: reportedMachineID.rawValue,
            machines: [
                rawMachine(
                    machineID: selfMachineID,
                    publicKey: selfMachineID.machinePublicKey,
                    isSelf: true
                ),
                rawMachine(
                    machineID: reportedMachineID,
                    publicKey: reportedMachineID.machinePublicKey,
                    isSelf: false
                )
            ]
        )

        try await assertRejectedRawInventoryLeavesStateUntouched(
            body: body,
            activeHousehold: activeHousehold,
            ownerKey: ownerKey,
            expectedError: .inconsistentSelfMachineBinding
        )
    }

    func testWrongMachinePublicKeyBootstrapLeavesProjectionAndServerStoreUntouched() async throws {
        let ownerKey = try machineKey(seed: 0x33)
        let activeHousehold = try householdState(id: "hh_current", ownerKey: ownerKey)
        let claimedMachineID = try machineID(seed: 0x22)
        let mismatchedPublicKey = try machineKey(seed: 0x23).publicKey.compressedRepresentation
        let body = try rawMachinesResponse(
            householdID: activeHousehold.householdId,
            selfMachineID: claimedMachineID.rawValue,
            machines: [
                rawMachine(
                    machineID: claimedMachineID,
                    publicKey: mismatchedPublicKey,
                    isSelf: true
                )
            ]
        )

        try await assertRejectedRawInventoryLeavesStateUntouched(
            body: body,
            activeHousehold: activeHousehold,
            ownerKey: ownerKey,
            expectedError: .machineIdentifierMismatch
        )
    }

    func testLegacyIdentifierOnlyBootstrapLeavesProjectionAndServerStoreUntouched() async throws {
        let ownerKey = try machineKey(seed: 0x33)
        let activeHousehold = try householdState(id: "hh_current", ownerKey: ownerKey)
        let machineID = try machineID(seed: 0x22)
        let body = try rawMachinesResponse(
            householdID: activeHousehold.householdId,
            selfMachineID: machineID.rawValue,
            machines: [rawMachine(machineID: machineID, publicKey: nil, isSelf: true)]
        )

        try await assertRejectedRawInventoryLeavesStateUntouched(
            body: body,
            activeHousehold: activeHousehold,
            ownerKey: ownerKey,
            expectedError: .unexpectedResponse
        )
    }
}

private extension BaseMachineProjectorTests {
    @MainActor
    struct StubAuthorityBootstrapper: BaseMachineAuthorityBootstrapping {
        let snapshot: HouseholdMachinesSnapshot

        func bootstrap(popSigner _: HouseholdPoPSigner) async throws -> HouseholdMachinesSnapshot {
            snapshot
        }
    }

    @MainActor
    struct FailingAuthorityBootstrapper: BaseMachineAuthorityBootstrapping {
        func bootstrap(popSigner _: HouseholdPoPSigner) async throws -> HouseholdMachinesSnapshot {
            throw MachineReachabilityAuthorityBootstrapError.noActiveHouseholdState
        }
    }

    @MainActor
    final class SwitchingAuthorityBootstrapper: BaseMachineAuthorityBootstrapping {
        let snapshot: HouseholdMachinesSnapshot
        let onBootstrap: () -> Void

        init(snapshot: HouseholdMachinesSnapshot, onBootstrap: @escaping () -> Void) {
            self.snapshot = snapshot
            self.onBootstrap = onBootstrap
        }

        func bootstrap(popSigner _: HouseholdPoPSigner) async throws -> HouseholdMachinesSnapshot {
            onBootstrap()
            return snapshot
        }
    }

    @MainActor
    final class ActiveHouseholdBox {
        var value: ActiveHouseholdState?

        init(_ value: ActiveHouseholdState?) {
            self.value = value
        }
    }

    actor BootstrapRequestRecorder {
        private var requests: [URLRequest] = []

        func record(_ request: URLRequest) {
            requests.append(request)
        }

        func recordedRequests() -> [URLRequest] {
            requests
        }
    }

    @MainActor
    struct RegistryFixture {
        let suiteName: String
        let defaults: UserDefaults
        let store: ServerStore
        let registry: ServerRegistry

        func clear() {
            registry.clearBaseMachineProjections()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func makeRegistry() -> RegistryFixture {
        let suiteName = "BaseMachineProjectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ServerStore(defaults: defaults)
        let registry = ServerRegistry(writer: ServerInventoryWriter(store: store))
        return RegistryFixture(
            suiteName: suiteName,
            defaults: defaults,
            store: store,
            registry: registry
        )
    }

    func machinesSnapshot(
        householdID: String,
        machineID: MachineID,
        hostLabel: String
    ) throws -> HouseholdMachinesSnapshot {
        let machine = HouseholdMachine(
            machineID: machineID,
            hostLabel: hostLabel,
            platform: "macos",
            isSelf: true,
            capabilities: ["engine", "pty"],
            joinedAt: 1_725_000_000
        )
        let authority = try MachineReachabilityAuthority(
            householdID: householdID,
            reportedSelfMachineID: machineID.rawValue,
            authenticatedSelfMachinePublicKey: machineID.machinePublicKey
        )
        return HouseholdMachinesSnapshot(
            householdID: householdID,
            selfMachine: machine,
            machines: [machine],
            reachabilityAuthority: authority
        )
    }

    func assertRejectedRawInventoryLeavesStateUntouched(
        body: Data,
        activeHousehold: ActiveHouseholdState,
        ownerKey: P256.Signing.PrivateKey,
        expectedError: HouseholdMachinesError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let registryFixture = makeRegistry()
        defer { registryFixture.clear() }
        let baselineMachineID = try machineID(seed: 0x11)
        registryFixture.registry.projectBaseMachine(
            householdID: activeHousehold.householdId,
            serverID: BaseMachineProjector.stableServerID(for: baselineMachineID),
            machineID: baselineMachineID,
            hostLabel: "mac-baseline",
            joinedAt: 1_725_000_000
        )
        let persistedServer = Server(
            id: "server-alpha",
            kind: .linux,
            pairedAt: Date(timeIntervalSince1970: 1_725_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_725_000_000),
            hostname: "linux-alpha",
            lastHost: "198.51.100.10"
        )
        registryFixture.registry.upsert(persistedServer)

        let expectedBaseMachines = registryFixture.registry.baseMachines
        let expectedServers = registryFixture.registry.servers
        let expectedStore = registryFixture.store.load()
        let sessionStore = HouseholdSessionStore(
            storage: TestInMemoryHouseholdStorage(),
            account: "base-machine-rejection-\(UUID().uuidString)"
        )
        let bootstrapHousehold = try roundTrippableHouseholdState(from: activeHousehold)
        try sessionStore.save(bootstrapHousehold)
        XCTAssertEqual(
            try sessionStore.load(),
            bootstrapHousehold,
            "The authority bootstrap fixture must survive the real session-store decode."
        )
        let recorder = BootstrapRequestRecorder()
        let bootstrapper = MachineReachabilityAuthorityBootstrapper(
            sessionStore: sessionStore,
            transport: { request in
                await recorder.record(request)
                return (
                    body,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }
        )
        let keyProvider = StubOwnerIdentityKeyProvider(privateKey: ownerKey)
        let ownerIdentity = try keyProvider.loadOwnerIdentity(
            keyReference: activeHousehold.signingKeyReference,
            publicKey: activeHousehold.signingPublicKey
        )
        let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity)

        do {
            _ = try await bootstrapper.bootstrap(popSigner: popSigner)
            XCTFail("The raw inventory mismatch must be rejected before projection.", file: file, line: line)
        } catch let error as HouseholdMachinesError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Expected HouseholdMachinesError \(expectedError), got \(error).", file: file, line: line)
        }
        let projector = BaseMachineProjector(
            authorityBootstrapper: bootstrapper,
            keyProvider: keyProvider,
            registry: registryFixture.registry,
            activeHousehold: { activeHousehold },
            canReadMachineInventory: { _ in true }
        )

        await projector.refresh()

        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.count, 2, "Preflight and projector must both exercise the raw response.", file: file, line: line)
        XCTAssertTrue(
            requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == HouseholdMachinesClient.path },
            "Each rejection must be the authenticated /machines bootstrap request.",
            file: file,
            line: line
        )
        XCTAssertEqual(registryFixture.registry.baseMachines, expectedBaseMachines, file: file, line: line)
        XCTAssertEqual(registryFixture.registry.servers, expectedServers, file: file, line: line)
        XCTAssertEqual(registryFixture.store.load(), expectedStore, file: file, line: line)
    }

    func rawMachinesResponse(
        householdID: String,
        selfMachineID: String,
        machines: [[String: Any]]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "hh_id": householdID,
            "self_m_id": selfMachineID,
            "machines": machines
        ])
    }

    func rawMachine(
        machineID: MachineID,
        publicKey: Data?,
        isSelf: Bool
    ) -> [String: Any] {
        var machine: [String: Any] = [
            "machine_id": machineID.rawValue,
            "host_label": "mac-alpha",
            "platform": "macos",
            "is_self": isSelf,
            "capabilities": ["engine", "pty"],
            "joined_at": 1_725_000_000
        ]
        if let publicKey {
            machine["machine_pub"] = lowerHex(publicKey)
        }
        return machine
    }

    func roundTrippableHouseholdState(
        from template: ActiveHouseholdState
    ) throws -> ActiveHouseholdState {
        let householdPrivateKey = try machineKey(seed: 0x44)
        let certCBOR = try signedOwnerCertCBOR(
            householdPrivateKey: householdPrivateKey,
            personPublicKey: template.ownerPublicKey,
            householdID: template.householdId
        )
        let personCert = try PersonCert(cbor: certCBOR)
        return ActiveHouseholdState(
            householdId: template.householdId,
            householdName: template.householdName,
            householdPublicKey: template.householdPublicKey,
            endpoint: template.endpoint,
            ownerPersonId: template.ownerPersonId,
            ownerPublicKey: template.ownerPublicKey,
            ownerKeyReference: template.ownerKeyReference,
            personCert: personCert,
            devicePublicKey: template.devicePublicKey,
            deviceKeyReference: template.deviceKeyReference,
            deviceCertCBOR: template.deviceCertCBOR,
            pairedAt: template.pairedAt,
            lastSeenAt: template.lastSeenAt
        )
    }

    func signedOwnerCertCBOR(
        householdPrivateKey: P256.Signing.PrivateKey,
        personPublicKey: Data,
        householdID: String
    ) throws -> Data {
        let personID = try HouseholdIdentifiers.personIdentifier(for: personPublicKey)
        let caveats = PersonCert.requiredOwnerOperations.sorted().map { operation in
            HouseholdCBORValue.map([
                "constraints": .null,
                "op": .text(operation),
                "scope": operation.hasPrefix("household.")
                    ? .null
                    : .map(["all": .bool(true)]),
            ])
        }
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        let unsignedCertificate = HouseholdCBORValue.map([
            "caveats": .array(caveats),
            "display_name": .text("Owner"),
            "hh_id": .text(householdID),
            "issued_at": .unsigned(UInt64(now.timeIntervalSince1970)),
            "issued_by": .text(householdID),
            "nonce": .bytes(Data(repeating: 9, count: 16)),
            "not_after": .null,
            "not_before": .unsigned(UInt64(now.timeIntervalSince1970 - 60)),
            "p_id": .text(personID),
            "p_pub": .bytes(personPublicKey),
            "type": .text("person"),
            "v": .unsigned(1),
        ])
        let signature = try householdPrivateKey
            .signature(for: HouseholdCBOR.encode(unsignedCertificate))
            .rawRepresentation
        guard case .map(var certificate) = unsignedCertificate else {
            throw NSError(domain: "BaseMachineProjectorTests", code: 0)
        }
        certificate["signature"] = .bytes(signature)
        return HouseholdCBOR.encode(.map(certificate))
    }

    func householdState(
        id: String,
        ownerKey: P256.Signing.PrivateKey
    ) throws -> ActiveHouseholdState {
        let householdPublicKey = try machineKey(seed: 0x44).publicKey.compressedRepresentation
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let personCert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: id,
            personId: try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey),
            personPublicKey: ownerPublicKey,
            displayName: "Owner",
            caveats: [],
            notBefore: .distantPast,
            notAfter: nil,
            issuedAt: nil,
            issuedBy: id,
            signature: Data(repeating: 0, count: 64)
        )
        return ActiveHouseholdState(
            householdId: id,
            householdName: "Example Household",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://engine.example.test")!,
            ownerPersonId: try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey),
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "test-owner-key",
            personCert: personCert,
            pairedAt: Date(timeIntervalSince1970: 1_725_000_000),
            lastSeenAt: nil
        )
    }

    func machineKey(seed: UInt8) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    }

    func machineID(seed: UInt8) throws -> MachineID {
        try MachineID(
            authenticatedMachinePublicKey: try machineKey(seed: seed)
                .publicKey.compressedRepresentation
        )
    }

    func lowerHex(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
