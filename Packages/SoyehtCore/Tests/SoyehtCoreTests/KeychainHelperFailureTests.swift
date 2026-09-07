import Foundation
import Security
import Testing
@testable import SoyehtCore

private final class MemoryKeychainOperations: KeychainOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool: Data]
    private var updates: [OSStatus]
    private var additions: [OSStatus]
    private var reads: [(OSStatus, Data?)]
    private var recorded: [String] = []

    init(primary: Data? = nil, legacy: Data? = nil,
         updates: [OSStatus] = [], additions: [OSStatus] = [],
         reads: [(OSStatus, Data?)] = []) {
        values = [:]
        values[true] = primary
        values[false] = legacy
        self.updates = updates
        self.additions = additions
        self.reads = reads
    }

    var calls: [String] { lock.withLock { recorded } }
    func value(primary: Bool) -> Data? { lock.withLock { values[primary] } }

    private func isPrimary(_ query: [String: Any]) -> Bool {
        #if os(macOS)
        return query[kSecUseDataProtectionKeychain as String] as? Bool == true
        #else
        return true
        #endif
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            recorded.append("update")
            let primary = isPrimary(query)
            let status = updates.isEmpty
                ? (values[primary] == nil ? errSecItemNotFound : errSecSuccess)
                : updates.removeFirst()
            if status == errSecSuccess { values[primary] = attributes[kSecValueData as String] as? Data }
            return status
        }
    }

    func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            recorded.append("add")
            let primary = isPrimary(query)
            let status = additions.isEmpty
                ? (values[primary] == nil ? errSecSuccess : errSecDuplicateItem)
                : additions.removeFirst()
            if status == errSecSuccess { values[primary] = query[kSecValueData as String] as? Data }
            if status == errSecDuplicateItem { values[primary] = Data("concurrent".utf8) }
            return status
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        lock.withLock {
            recorded.append("read")
            if !reads.isEmpty {
                let (status, data) = reads.removeFirst()
                return (status, data as NSData?)
            }
            if let data = values[isPrimary(query)] { return (errSecSuccess, data as NSData) }
            return (errSecItemNotFound, nil)
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            recorded.append("delete")
            values[isPrimary(query)] = nil
            return errSecSuccess
        }
    }
}

@Suite("Keychain failure preservation")
struct KeychainHelperFailureTests {
    private let old = Data("previous-value".utf8)
    private let new = Data("replacement-value".utf8)

    private func helper(_ operations: MemoryKeychainOperations) -> KeychainHelper {
        KeychainHelper(service: "test.in-memory-only", operations: operations)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func failedReplacementPreservesPreviousValue(status: OSStatus) {
        let operations = MemoryKeychainOperations(primary: old, updates: [status])
        #expect(!helper(operations).save(new, account: "session"))
        #expect(operations.value(primary: true) == old)
        #expect(operations.calls == ["update"])
    }

    @Test func replacementAndInsertionNeverDelete() {
        let existing = MemoryKeychainOperations(primary: old)
        #expect(helper(existing).save(new, account: "session"))
        #expect(existing.value(primary: true) == new)
        #expect(existing.calls == ["update"])
        let empty = MemoryKeychainOperations()
        #expect(helper(empty).save(new, account: "session"))
        #expect(empty.value(primary: true) == new)
        #expect(empty.calls == ["update", "add"])
    }

    @Test func failedInsertionDoesNotClaimSuccess() {
        let operations = MemoryKeychainOperations(additions: [errSecNotAvailable])
        #expect(!helper(operations).save(new, account: "session"))
        #expect(operations.value(primary: true) == nil)
        #expect(operations.calls == ["update", "add"])
    }

    @Test(arguments: [errSecSuccess, errSecAuthFailed])
    func concurrentInsertionRetriesOnceWithoutDeleting(status: OSStatus) {
        let operations = MemoryKeychainOperations(updates: [errSecItemNotFound, status],
                                                  additions: [errSecDuplicateItem])
        #expect(helper(operations).save(new, account: "session") == (status == errSecSuccess))
        #expect(operations.calls == ["update", "add", "update"])
        #expect(operations.value(primary: true) == (status == errSecSuccess ? new : Data("concurrent".utf8)))
    }

    @Test func sessionStorePropagatesReadFailureAcrossStorageProtocol() {
        let operations = MemoryKeychainOperations(reads: [(errSecInteractionNotAllowed, nil)])
        let store = HouseholdSessionStore(storage: helper(operations))
        #expect(throws: OwnerIdentityKeyError.securityFailure(
            domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))) { try store.load() }
        #expect(operations.calls == ["read"])
    }

    @Test func absenceIsDifferentFromMalformedSuccessfulRead() throws {
        #expect(try helper(MemoryKeychainOperations()).loadWithoutInteraction(account: "session") == nil)
        let invalid = MemoryKeychainOperations(reads: [(errSecSuccess, nil)])
        #expect(throws: HouseholdSessionError.decodingFailed) {
            try helper(invalid).loadWithoutInteraction(account: "session")
        }
    }

    @Test func unreadableRevocationsCannotBecomeAnEmptyCRL() async throws {
        let operations = MemoryKeychainOperations(reads: [(errSecInteractionNotAllowed, nil)])
        #expect(throws: OwnerIdentityKeyError.securityFailure(
            domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))) {
                try CRLStore(storage: helper(operations))
        }
        #expect(operations.calls == ["read"])
        let empty = try CRLStore(storage: helper(MemoryKeychainOperations()))
        #expect(await empty.snapshotEntries().isEmpty)
    }

    @Test func unreadableRosterIsRejectedRatherThanDeclaredAbsent() async {
        let operations = MemoryKeychainOperations(reads: [(errSecInteractionNotAllowed, nil)])
        let store = RosterProjectionStore(
            expectedHouseholdId: "test-household",
            householdPublicKey: Data(repeating: 1, count: 32), storage: helper(operations)
        )
        #expect(await store.lastRejection() == .storageUnavailable)
    }

    #if os(macOS)
    @Test func fallbackReplacementPreservesLegacyValueOnFailure() {
        let operations = MemoryKeychainOperations(legacy: old,
            updates: [errSecMissingEntitlement, errSecAuthFailed])
        #expect(!helper(operations).save(new, account: "session"))
        #expect(operations.value(primary: false) == old)
        #expect(operations.calls == ["update", "update"])
    }

    @Test func fallbackCanReadLegacyButCannotProvePrimaryAbsent() throws {
        let available = MemoryKeychainOperations(reads: [(errSecMissingEntitlement, nil), (errSecSuccess, old)])
        #expect(try helper(available).loadWithoutInteraction(account: "session") == old)
        let unavailable = MemoryKeychainOperations(reads: [(errSecMissingEntitlement, nil), (errSecItemNotFound, nil)])
        #expect(throws: OwnerIdentityKeyError.securityFailure(
            domain: NSOSStatusErrorDomain, code: Int(errSecMissingEntitlement))) {
                try helper(unavailable).loadWithoutInteraction(account: "session")
        }
    }

    @Test func missingPrimaryCanReadLegacy() throws {
        let operations = MemoryKeychainOperations(legacy: old)
        #expect(try helper(operations).loadWithoutInteraction(account: "session") == old)
        #expect(operations.calls == ["read", "read"])
    }
    #endif
}
