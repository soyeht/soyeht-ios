import Foundation
import SoyehtCore

enum JoinExistingCapability {
    static let minimumEngineVersion = SemanticVersion(0, 1, 19)

    static func isAvailable(status: BootstrapStatusResponse) -> Bool {
        guard let current = SemanticVersion(status.engineVersion) else {
            return false
        }
        return current >= minimumEngineVersion
    }
}

struct SemanticVersion: Comparable, Sendable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        let core = raw.split(separator: "-", maxSplits: 1).first ?? Substring(raw)
        let parts = core.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        self.init(major, minor, patch)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
