import Security
import XCTest
@testable import SoyehtMacDomain

@MainActor
final class PairingStoreRevocationTests: XCTestCase {
    private let pairedDevicesKey = "com.soyeht.mac.pairedDevices"
    private let revokedDevicesKey = "com.soyeht.mac.revokedDevices"

    func testRevokeRollsBackOnlyWhenDenyListPersistenceFails() {
        let fixture = makeStore()
        let deviceID = UUID()
        _ = fixture.store.pair(deviceID: deviceID, name: "device-alpha", model: "iPhone")
        fixture.defaults.failingDataKeys.insert(revokedDevicesKey)
        var changeCount = 0
        fixture.store.onChange = { changeCount += 1 }

        let result = fixture.store.revoke(deviceID: deviceID)

        XCTAssertEqual(result, .failed(.denyListPersistenceFailed))
        XCTAssertFalse(fixture.store.isRevoked(deviceID: deviceID))
        XCTAssertTrue(fixture.store.isPaired(deviceID: deviceID))
        XCTAssertNotNil(fixture.secrets.loadString(account: secretAccount(deviceID)))
        XCTAssertEqual(changeCount, 0)
    }

    func testRevokeKeepsDenyListCommittedWhenPairedMetadataCleanupFails() {
        let fixture = makeStore()
        let deviceID = UUID()
        _ = fixture.store.pair(deviceID: deviceID, name: "device-alpha", model: "iPhone")
        fixture.defaults.failingDataKeys.insert(pairedDevicesKey)

        let result = fixture.store.revoke(deviceID: deviceID)

        XCTAssertEqual(
            result,
            .revoked(existed: true, warnings: [.pairedMetadataCleanupFailed])
        )
        XCTAssertTrue(fixture.store.isRevoked(deviceID: deviceID))
        XCTAssertNotNil(fixture.store.device(id: deviceID))

        let reloaded = PairingStore(defaults: fixture.defaults, keychain: fixture.secrets, clock: fixedClock)
        XCTAssertTrue(reloaded.isRevoked(deviceID: deviceID))
        XCTAssertNotNil(reloaded.device(id: deviceID))
        XCTAssertFalse(reloaded.isPaired(deviceID: deviceID))
    }

    func testRevokeKeepsDenyListCommittedWhenKeychainCleanupFails() {
        let fixture = makeStore()
        let deviceID = UUID()
        _ = fixture.store.pair(deviceID: deviceID, name: "device-alpha", model: "iPhone")
        fixture.secrets.deleteStatuses[secretAccount(deviceID)] = errSecInteractionNotAllowed

        let result = fixture.store.revoke(deviceID: deviceID)

        XCTAssertEqual(
            result,
            .revoked(existed: true, warnings: [.keychainSecretCleanupFailed])
        )
        XCTAssertTrue(fixture.store.isRevoked(deviceID: deviceID))
        XCTAssertNil(fixture.store.device(id: deviceID))
        XCTAssertNotNil(fixture.secrets.loadString(account: secretAccount(deviceID)))

        let reloaded = PairingStore(defaults: fixture.defaults, keychain: fixture.secrets, clock: fixedClock)
        XCTAssertTrue(reloaded.isRevoked(deviceID: deviceID))
        XCTAssertFalse(reloaded.isPaired(deviceID: deviceID))
    }

    func testRevokeAllKeepsDenyListCommittedWhenPairedMetadataCleanupFails() {
        let fixture = makeStore()
        let first = UUID()
        let second = UUID()
        _ = fixture.store.pair(deviceID: first, name: "device-alpha", model: "iPhone")
        _ = fixture.store.pair(deviceID: second, name: "device-beta", model: "iPhone")
        fixture.defaults.failingDataKeys.insert(pairedDevicesKey)

        let result = fixture.store.revokeAll()

        XCTAssertEqual(Set(result.effectivelyRevokedDeviceIDs), [first, second])
        XCTAssertTrue(result.hasCleanupWarnings)
        XCTAssertTrue(fixture.store.isRevoked(deviceID: first))
        XCTAssertTrue(fixture.store.isRevoked(deviceID: second))
        XCTAssertNotNil(fixture.store.device(id: first))
        XCTAssertNotNil(fixture.store.device(id: second))

        let reloaded = PairingStore(defaults: fixture.defaults, keychain: fixture.secrets, clock: fixedClock)
        XCTAssertTrue(reloaded.isRevoked(deviceID: first))
        XCTAssertTrue(reloaded.isRevoked(deviceID: second))
    }

    func testPairedDevicesWindowDisconnectsOnlyAfterEffectiveRevocation() throws {
        let source = try macSource("Pairing/PairedDevicesWindowController.swift")
        let single = try slice(
            source,
            from: "@MainActor @objc private func revokeSelectedTapped()",
            to: "@MainActor @objc private func revokeAllTapped()"
        )
        let bulk = try slice(
            source,
            from: "@MainActor @objc private func revokeAllTapped()",
            to: "@MainActor\n    private func confirmRevoke"
        )

        XCTAssertTrue(single.contains("let result = PairingStore.shared.revoke(deviceID: device.deviceID)"))
        XCTAssertTrue(single.contains("if result.isEffectivelyRevoked"))
        XCTAssertLessThan(
            try XCTUnwrap(single.range(of: "PairingStore.shared.revoke")?.lowerBound),
            try XCTUnwrap(single.range(of: "LocalTerminalHandoffManager.shared.disconnectDevice")?.lowerBound)
        )

        XCTAssertTrue(bulk.contains("let result = PairingStore.shared.revokeAll()"))
        XCTAssertTrue(bulk.contains("for deviceID in result.effectivelyRevokedDeviceIDs"))
    }

    private func makeStore() -> (store: PairingStore, defaults: FakePairingDefaults, secrets: FakePairingSecrets) {
        let defaults = FakePairingDefaults()
        let secrets = FakePairingSecrets()
        let store = PairingStore(defaults: defaults, keychain: secrets, clock: fixedClock)
        return (store, defaults, secrets)
    }

    private func secretAccount(_ deviceID: UUID) -> String {
        "pairing_secret.\(deviceID.uuidString.lowercased())"
    }

    private func fixedClock() -> Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac")
        return try String(contentsOf: terminalApp.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            throw XCTSkip("source markers not found")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private final class FakePairingDefaults: PairingDefaultsStoring {
    var failingDataKeys: Set<String> = []
    private var values: [String: Any] = [:]

    func pairingString(forKey key: String) -> String? {
        values[key] as? String
    }

    func pairingData(forKey key: String) -> Data? {
        values[key] as? Data
    }

    @discardableResult
    func setPairingString(_ value: String, forKey key: String) -> Bool {
        values[key] = value
        return true
    }

    @discardableResult
    func setPairingData(_ value: Data, forKey key: String) -> Bool {
        guard !failingDataKeys.contains(key) else { return false }
        values[key] = value
        return true
    }

    func removePairingObject(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

private final class FakePairingSecrets: PairingSecretStoring {
    var deleteStatuses: [String: OSStatus] = [:]
    private var values: [String: String] = [:]

    @discardableResult
    func save(_ data: Data, account: String) -> Bool {
        values[account] = String(data: data, encoding: .utf8)
        return values[account] != nil
    }

    func loadString(account: String) -> String? {
        values[account]
    }

    @discardableResult
    func deleteStatus(account: String) -> OSStatus {
        let status = deleteStatuses[account] ?? errSecSuccess
        if status == errSecSuccess {
            values.removeValue(forKey: account)
        }
        return status
    }
}
