import CryptoKit
import Foundation
import XCTest
import SoyehtCore
import UIKit
@testable import Soyeht

/// Covers the `SoyehtIdentity` quad-state contract — `.unknown` /
/// `.inactive` / `.active(snapshot)` / `.unavailable(reason)` — plus
/// the snapshot wrapper and `OwnerDevice` accessor. The state enum
/// replaces the legacy `try? store.load() != nil` pattern that
/// collapsed three distinct conditions into a single Bool; these
/// tests guard the distinction so a future refactor can't silently
/// re-introduce the collapse.
@MainActor
final class SoyehtIdentityTests: XCTestCase {

    // MARK: - State machine

    func testReload_movesToInactive_whenStoreEmpty() {
        let identity = makeIdentity(storage: MemoryStorage())

        XCTAssertEqual(identity.state, .inactive)
        XCTAssertFalse(identity.isActive)
        XCTAssertNil(identity.active)
    }

    func testReload_movesToActive_whenStoreHasEntry() throws {
        let household = try Self.makeHousehold()
        let storage = MemoryStorage()
        try storage.write(household)

        let identity = makeIdentity(storage: storage)

        guard case .active(let snapshot) = identity.state else {
            return XCTFail("expected .active state, got \(identity.state)")
        }
        XCTAssertEqual(snapshot.id, household.householdId)
        XCTAssertTrue(identity.isActive)
        XCTAssertEqual(identity.active?.id, household.householdId)
    }

    func testReload_movesToUnavailable_decodingFailed_whenStoreThrows() {
        let storage = MemoryStorage()
        storage.payload = Data("not a real ActiveHouseholdState".utf8)

        let identity = makeIdentity(storage: storage)

        XCTAssertEqual(identity.state, .unavailable(.decodingFailed))
        XCTAssertFalse(identity.isActive,
            "Decode failure must NOT be treated as inactive — the entry exists and the user may already be paired."
        )
        XCTAssertNil(identity.active)
    }

    func testReload_movesToUnavailable_protectedDataUnavailable_whenLocked() throws {
        let household = try Self.makeHousehold()
        let storage = MemoryStorage()
        try storage.write(household)

        let identity = makeIdentity(
            storage: storage,
            isProtectedDataAvailable: { false }
        )

        XCTAssertEqual(identity.state, .unavailable(.protectedDataUnavailable))
        XCTAssertFalse(identity.isActive,
            "Locked Keychain must NOT be treated as active — the snapshot is unreadable."
        )
    }

    func testReload_promotesUnavailable_toActive_whenProtectedDataBecomesAvailable() throws {
        let household = try Self.makeHousehold()
        let storage = MemoryStorage()
        try storage.write(household)

        let availability = AvailabilityFlag(initial: false)
        let identity = makeIdentity(
            storage: storage,
            isProtectedDataAvailable: { availability.value }
        )
        XCTAssertEqual(identity.state, .unavailable(.protectedDataUnavailable))

        availability.value = true
        identity.reload()

        guard case .active = identity.state else {
            return XCTFail("expected .active after protected data became available, got \(identity.state)")
        }
    }

    func testProtectedDataDidBecomeAvailable_triggersReload() async throws {
        let household = try Self.makeHousehold()
        let storage = MemoryStorage()
        try storage.write(household)

        // Private NotificationCenter so this post does not reach a
        // `SoyehtIdentity.shared` instance that another test path may
        // have spun up (e.g. `HouseholdPairingViewModelTests.pairNow`
        // calls `.shared.reload()` and registers observers on
        // `.default` for the rest of the process lifetime).
        let center = NotificationCenter()
        let availability = AvailabilityFlag(initial: false)
        let identity = makeIdentity(
            storage: storage,
            isProtectedDataAvailable: { availability.value },
            notificationCenter: center
        )
        XCTAssertEqual(identity.state, .unavailable(.protectedDataUnavailable))

        availability.value = true
        center.post(
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        // Observer hops onto the main actor via Task; one runloop tick
        // is enough to let the dispatched reload run.
        await Task.yield()

        guard case .active = identity.state else {
            return XCTFail("expected .active after protectedDataDidBecomeAvailable, got \(identity.state)")
        }
    }

    func testHouseCreatedReceived_triggersReload() async throws {
        let storage = MemoryStorage()
        let center = NotificationCenter()
        let identity = makeIdentity(storage: storage, notificationCenter: center)
        XCTAssertEqual(identity.state, .inactive)

        // Simulate the engine push: write the entry, then fire the
        // notification that mirrors `HouseCreatedPushHandler`. Post
        // on the injected private center so the shared singleton (if
        // already spun up by another test) is not also reloaded.
        let household = try Self.makeHousehold()
        try storage.write(household)
        center.post(
            name: HouseCreatedPushHandler.houseCreatedReceived,
            object: nil
        )
        await Task.yield()

        guard case .active(let snapshot) = identity.state else {
            return XCTFail("expected .active after houseCreatedReceived, got \(identity.state)")
        }
        XCTAssertEqual(snapshot.id, household.householdId)
    }

    // MARK: - Snapshot accessors

    func testSnapshot_id_isHouseholdId() throws {
        let household = try Self.makeHousehold()
        let snapshot = SoyehtIdentitySnapshot(raw: household)
        XCTAssertEqual(snapshot.id, household.householdId)
    }

    func testSnapshot_displayName_isHouseholdName() throws {
        let household = try Self.makeHousehold(name: "Caio's Home")
        let snapshot = SoyehtIdentitySnapshot(raw: household)
        XCTAssertEqual(snapshot.displayName, "Caio's Home")
    }

    func testSnapshot_endpoint_isStoreEndpoint() throws {
        let household = try Self.makeHousehold()
        let snapshot = SoyehtIdentitySnapshot(raw: household)
        XCTAssertEqual(snapshot.endpoint, household.endpoint)
    }

    func testSnapshot_underlying_returnsExactStoredState() throws {
        let household = try Self.makeHousehold()
        let snapshot = SoyehtIdentitySnapshot(raw: household)
        XCTAssertEqual(snapshot.underlying, household)
    }

    func testSnapshot_allows_delegatesToPersonCert() throws {
        // `makeHousehold` constructs a PersonCert with every operation
        // in `PersonCert.requiredOwnerOperations`. The snapshot's
        // `allows(_:)` must reflect that.
        let household = try Self.makeHousehold()
        let snapshot = SoyehtIdentitySnapshot(raw: household)
        for op in PersonCert.requiredOwnerOperations {
            XCTAssertTrue(snapshot.allows(op), "expected snapshot.allows(\(op)) to mirror the underlying PersonCert")
        }
        XCTAssertFalse(snapshot.allows("synthetic.never.allowed"))
    }

    // MARK: - OwnerDevice

    func testThisDevice_alwaysAvailable_evenWithoutTenant() {
        let identity = makeIdentity(storage: MemoryStorage())

        XCTAssertEqual(identity.state, .inactive)
        XCTAssertEqual(identity.thisDevice.displayName, "Test iPhone")
        XCTAssertEqual(identity.thisDevice.model, "iPhone15,2")
        XCTAssertTrue(identity.thisDevice.isThisDevice)
    }

    func testThisDevice_localPairingDeviceId_isInjectedValue() {
        let injected = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let identity = makeIdentity(
            storage: MemoryStorage(),
            localPairingDeviceId: injected
        )

        XCTAssertEqual(identity.thisDevice.localPairingDeviceId, injected)
    }

    // MARK: - Conveniences

    func testIsActive_isTrue_onlyForActiveState() throws {
        let storage = MemoryStorage()
        let active = makeIdentity(storage: storage)
        XCTAssertFalse(active.isActive)

        try storage.write(try Self.makeHousehold())
        active.reload()
        XCTAssertTrue(active.isActive)

        storage.payload = Data("malformed".utf8)
        active.reload()
        XCTAssertFalse(active.isActive,
            ".unavailable(.decodingFailed) must report isActive == false"
        )
    }

    func testActive_isNil_forUnknownInactiveUnavailable() {
        // Empty storage → .inactive
        let inactiveStorage = MemoryStorage()
        XCTAssertNil(makeIdentity(storage: inactiveStorage).active)

        // Malformed storage → .unavailable(.decodingFailed)
        let corruptStorage = MemoryStorage()
        corruptStorage.payload = Data("not json".utf8)
        XCTAssertNil(makeIdentity(storage: corruptStorage).active)

        // Locked storage → .unavailable(.protectedDataUnavailable)
        let lockedStorage = MemoryStorage()
        XCTAssertNil(
            makeIdentity(storage: lockedStorage, isProtectedDataAvailable: { false }).active
        )
    }

    // MARK: - Helpers

    private func makeIdentity(
        storage: MemoryStorage,
        localPairingDeviceId: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        deviceModel: String = "iPhone15,2",
        deviceDisplayName: String = "Test iPhone",
        isProtectedDataAvailable: @escaping () -> Bool = { true },
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> SoyehtIdentity {
        let store = HouseholdSessionStore(
            storage: storage,
            account: HouseholdSessionStore.activeSessionAccount
        )
        // Inject a private `NotificationCenter` by default so test
        // posts on `UIApplication.protectedDataDidBecomeAvailableNotification`
        // / `HouseCreatedPushHandler.houseCreatedReceived` do not also
        // wake a production `SoyehtIdentity.shared` instance that a
        // sibling test may have spun up. The controller's `refresh()`
        // is not invoked in these tests, so the shared instance is
        // safe to thread through — `SoyehtIdentity.reload()` reads the
        // injected store directly, never the controller's cached
        // `active`.
        return SoyehtIdentity(
            store: store,
            controller: HouseholdSessionController.shared,
            localPairingDeviceId: localPairingDeviceId,
            deviceModel: deviceModel,
            deviceDisplayName: deviceDisplayName,
            isProtectedDataAvailable: isProtectedDataAvailable,
            notificationCenter: notificationCenter
        )
    }

    /// Builds a fully round-trippable `ActiveHouseholdState`. Unlike the
    /// fixtures in `HouseholdApplePushServiceViewModelTests`, this one
    /// has to survive `HouseholdSessionStore.save → load` via real CBOR
    /// because `PersonCert`'s Codable encodes only `rawCBOR` and the
    /// decoder re-parses every field from those bytes. A trivial empty
    /// CBOR map (`Data([0xA0])`) makes `PersonCert(cbor:)` throw and
    /// the entire ActiveHouseholdState fails to decode.
    private static func makeHousehold(
        seed: UInt8 = 0xAA,
        name: String = "Sample Home"
    ) throws -> ActiveHouseholdState {
        let householdKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed &+ 1, count: 32))
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let certCBOR = try Self.signedOwnerCertCBOR(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey,
            householdId: householdId
        )
        let cert = try PersonCert(cbor: certCBOR)
        return ActiveHouseholdState(
            householdId: householdId,
            householdName: name,
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://household.example")!,
            ownerPersonId: try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey),
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "test-owner",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil
        )
    }

    /// Replica do helper `SoyehtCoreTests.HouseholdTestFixtures.signedOwnerCert`
    /// (que vive na suite de testes de `SoyehtCore` e não é exposta ao
    /// app target). Reproduzido aqui — no app target — exclusivamente
    /// para que `ActiveHouseholdState.personCert` sobreviva ao
    /// round-trip JSON → CBOR → `PersonCert(cbor:)`. Mantemos os campos
    /// e a ordem idênticos ao fixture canônico.
    private static func signedOwnerCertCBOR(
        householdPrivateKey: P256.Signing.PrivateKey,
        personPublicKey: Data,
        householdId: String,
        now: Date = Date(timeIntervalSince1970: 1_714_972_800)
    ) throws -> Data {
        let personId = try HouseholdIdentifiers.personIdentifier(for: personPublicKey)
        let caveats = PersonCert.requiredOwnerOperations.sorted().map { op in
            HouseholdCBORValue.map([
                "constraints": .null,
                "op": .text(op),
                "scope": op.hasPrefix("household.") ? .null : .map(["all": .bool(true)]),
            ])
        }
        let withoutSignature = HouseholdCBORValue.map([
            "caveats": .array(caveats),
            "display_name": .text("Owner"),
            "hh_id": .text(householdId),
            "issued_at": .unsigned(UInt64(now.timeIntervalSince1970)),
            "issued_by": .text(householdId),
            "nonce": .bytes(Data(repeating: 9, count: 16)),
            "not_after": .null,
            "not_before": .unsigned(UInt64(now.timeIntervalSince1970 - 60)),
            "p_id": .text(personId),
            "p_pub": .bytes(personPublicKey),
            "type": .text("person"),
            "v": .unsigned(1),
        ])
        let signingBytes = HouseholdCBOR.encode(withoutSignature)
        let signature = try householdPrivateKey.signature(for: signingBytes).rawRepresentation
        guard case .map(var map) = withoutSignature else {
            throw NSError(domain: "SoyehtIdentityTests", code: 0)
        }
        map["signature"] = .bytes(signature)
        return HouseholdCBOR.encode(.map(map))
    }
}

// MARK: - Test doubles

/// In-memory `HouseholdSecureStoring` so tests can stage every
/// failure mode the Keychain layer collapses to nil: empty
/// (`payload == nil`), populated (well-formed JSON), and corrupt
/// (malformed bytes that decode-throws).
private final class MemoryStorage: HouseholdSecureStoring, @unchecked Sendable {
    var payload: Data?

    init(payload: Data? = nil) {
        self.payload = payload
    }

    func write(_ household: ActiveHouseholdState) throws {
        payload = try JSONEncoder().encode(household)
    }

    func save(_ data: Data, account: String) -> Bool {
        payload = data
        return true
    }

    func load(account: String) -> Data? {
        payload
    }

    func delete(account: String) {
        payload = nil
    }
}

/// Mutable flag whose changes are reflected by the `() -> Bool`
/// closure handed to `SoyehtIdentity`. Lets a test simulate the lock
/// → unlock transition without touching `UIApplication`.
private final class AvailabilityFlag: @unchecked Sendable {
    var value: Bool
    init(initial: Bool) { value = initial }
}
