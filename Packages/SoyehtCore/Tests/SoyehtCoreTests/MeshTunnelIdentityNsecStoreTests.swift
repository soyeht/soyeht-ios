import Foundation
import P256K
import Security
import XCTest

@testable import SoyehtCore

final class MeshTunnelIdentityNsecStoreTests: XCTestCase {
    func testAccessGroupRequiresResolvedSoyehtMeshGroup() throws {
        XCTAssertEqual(
            try MeshTunnelKeychainAccessGroup(
                resolvedValue: "TEAMID.com.soyeht.mobile.clawshare.mesh"
            ).value,
            "TEAMID.com.soyeht.mobile.clawshare.mesh"
        )
        XCTAssertEqual(
            try MeshTunnelKeychainAccessGroup(
                resolvedValue: "TEAMID.com.soyeht.mobile.clawshare.mesh.dev"
            ).value,
            "TEAMID.com.soyeht.mobile.clawshare.mesh.dev"
        )
        for malformed in [
            "$(AppIdentifierPrefix)com.soyeht.mobile.clawshare.mesh",
            "com.soyeht.mobile.clawshare.mesh",
            "TEAM.example.com.soyeht.mobile.clawshare.mesh ",
            "TEAM.example.com.soyeht.mobile.clawshare.other",
        ] {
            XCTAssertThrowsError(try MeshTunnelKeychainAccessGroup(resolvedValue: malformed)) { error in
                XCTAssertEqual(error as? MeshTunnelIdentityNsecStoreError, .invalidAccessGroup)
            }
        }
    }

    func testStoreScopesEveryKeychainOperationToExplicitSharedGroup() throws {
        let operations = RecordingKeychain()
        operations.updateStatus = errSecItemNotFound
        let accessGroup = try MeshTunnelKeychainAccessGroup(
            resolvedValue: "TEAMID.com.soyeht.mobile.clawshare.mesh.dev"
        )
        let store = MeshTunnelIdentityNsecStore(
            accessGroup: accessGroup,
            service: "com.soyeht.tests.mesh",
            account: "identity",
            operations: operations
        )
        let secret = validSecret()

        try store.saveIdentitySecret(secret)
        operations.readResult = .success(secret)
        XCTAssertEqual(try store.loadIdentitySecret(), secret)
        try store.deleteIdentitySecret()

        XCTAssertEqual(operations.updateQueries.count, 1)
        XCTAssertEqual(operations.addQueries.count, 1)
        XCTAssertEqual(operations.copyQueries.count, 1)
        XCTAssertEqual(operations.deleteQueries.count, 1)

        let allQueries = operations.updateQueries
            + operations.addQueries
            + operations.copyQueries
            + operations.deleteQueries
        for query in allQueries {
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, accessGroup.value)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.soyeht.tests.mesh")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "identity")
        }
        XCTAssertEqual(
            operations.updateAttributes.first?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(
            operations.addQueries.first?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(operations.addQueries.first?[kSecValueData as String] as? Data, secret)
    }

    func testStoreFailsClosedForMissingUnavailableOrInvalidSecret() throws {
        let accessGroup = try MeshTunnelKeychainAccessGroup(
            resolvedValue: "TEAMID.com.soyeht.mobile.clawshare.mesh"
        )
        let operations = RecordingKeychain()
        let store = MeshTunnelIdentityNsecStore(
            accessGroup: accessGroup,
            service: "com.soyeht.tests.mesh",
            account: "identity",
            operations: operations
        )

        operations.readResult = .failure(errSecItemNotFound)
        XCTAssertThrowsError(try store.loadIdentitySecret()) { error in
            XCTAssertEqual(error as? MeshTunnelIdentityNsecStoreError, .itemNotFound)
        }
        operations.readResult = .failure(errSecAuthFailed)
        XCTAssertThrowsError(try store.loadIdentitySecret()) { error in
            XCTAssertEqual(error as? MeshTunnelIdentityNsecStoreError, .itemUnavailable)
        }
        operations.readResult = .success(Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try store.loadIdentitySecret()) { error in
            XCTAssertEqual(error as? MeshTunnelIdentityNsecStoreError, .invalidIdentitySecret)
        }
        XCTAssertThrowsError(try store.saveIdentitySecret(Data(repeating: 0, count: 31))) { error in
            XCTAssertEqual(error as? MeshTunnelIdentityNsecStoreError, .invalidIdentitySecret)
        }
    }

    func testStoreDoesNotDeleteBeforeAWrite() throws {
        let accessGroup = try MeshTunnelKeychainAccessGroup(
            resolvedValue: "TEAMID.com.soyeht.mobile.clawshare.mesh"
        )
        let operations = RecordingKeychain()
        operations.updateStatus = errSecAuthFailed
        let store = MeshTunnelIdentityNsecStore(
            accessGroup: accessGroup,
            service: "com.soyeht.tests.mesh",
            account: "identity",
            operations: operations
        )

        XCTAssertThrowsError(try store.saveIdentitySecret(validSecret())) { error in
            XCTAssertEqual(error as? MeshTunnelIdentityNsecStoreError, .itemUnavailable)
        }
        XCTAssertTrue(operations.deleteQueries.isEmpty)
        XCTAssertTrue(operations.addQueries.isEmpty)
    }

    private func validSecret() -> Data {
        let secret = Data(repeating: 0x11, count: 32)
        XCTAssertNotNil(try? P256K.Schnorr.PrivateKey(dataRepresentation: secret))
        return secret
    }
}

private final class RecordingKeychain: MeshTunnelKeychainOperating, @unchecked Sendable {
    var readResult: MeshTunnelKeychainReadResult = .failure(errSecItemNotFound)
    var updateStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    private(set) var copyQueries: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var addQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    func copyMatching(_ query: [String: Any]) -> MeshTunnelKeychainReadResult {
        copyQueries.append(query)
        return readResult
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateQueries.append(query)
        updateAttributes.append(attributes)
        return updateStatus
    }

    func add(_ query: [String: Any]) -> OSStatus {
        addQueries.append(query)
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deleteQueries.append(query)
        return deleteStatus
    }
}
