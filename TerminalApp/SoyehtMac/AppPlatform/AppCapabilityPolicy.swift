import Foundation

/// Closed capability vocabulary. Unknown manifest strings never gain authority.
enum AppCapability: String, Codable, CaseIterable, Hashable {
    case metricsRead = "metrics.read"
}

enum AppCapabilityPolicy {
    static func allows(installID: String, command: CapabilityCommand) -> Bool {
        guard let manifest = AppInstallStore.record(installID: installID)?.manifest,
              let capability = AppCapability(rawValue: command.rawValue) else { return false }
        return manifest.capabilities.contains(capability.rawValue)
    }

    static func validate(_ declarations: [String]) throws {
        guard declarations.allSatisfy({ AppCapability(rawValue: $0) != nil }) else {
            throw AppManifestError.unknownCapability
        }
    }
}
