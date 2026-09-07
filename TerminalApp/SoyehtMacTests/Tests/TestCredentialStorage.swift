import Foundation
import SoyehtCore

/// Per-test credentials with no Security API access or persistent state.
final class TestCredentialStorage: HouseholdSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func save(_ data: Data, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[account] = data
        return true
    }

    func load(account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}
