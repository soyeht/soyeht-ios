import Foundation

/// Metadata-only audit trail. Never place request bodies, paths, or hosts here.
struct CapabilityAuditEntry: Codable, Hashable {
    enum Result: String, Codable, Hashable { case allowed, denied, rateLimited, malformed }
    let paneID: String
    let origin: String
    let appID: String
    let capability: String
    let result: Result
    let date: Date
}

final class CapabilityAuditLog {
    static let shared = CapabilityAuditLog()
    private let lock = NSLock()
    private(set) var entries: [CapabilityAuditEntry] = []

    static func record(paneID: String, origin: String, appID: String, command: String, result: CapabilityAuditEntry.Result) {
        shared.append(paneID: paneID, origin: origin, appID: appID, command: command, result: result)
    }

    private func append(paneID: String, origin: String, appID: String, command: String, result: CapabilityAuditEntry.Result) {
        lock.lock(); defer { lock.unlock() }
        entries.append(CapabilityAuditEntry(paneID: paneID, origin: origin, appID: appID, capability: command, result: result, date: Date()))
    }
}
