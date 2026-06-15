import Foundation
import SoyehtCore

/// Conversion from the legacy iOS `PairedMac` into the unified `Server`
/// model defined in `SoyehtCore`. Used by `ServerStore.migrateLegacyIfNeeded`
/// at first launch after the v1 ServerStore lands.
///
/// `PairedMac.macID` (a UUID) becomes `Server.id` as its `uuidString`, so
/// downstream Keychain lookups (e.g. `pairing_secret.{id}`) can keep
/// using the same accounts without rewriting Keychain entries during
/// migration.
extension PairedMac {
    /// Lossless adapter to `Server`. The user's typed alias, the
    /// presence/attach ports, the hostname (`name`), and the routing
    /// hint (`lastHost`) all flow through. `theyOS` starts as
    /// `.unknown` — `TheyOSStatusPoller` (Phase 5) populates it on the
    /// first foreground tick.
    public func toServer() -> Server {
        Server(
            id: macID.uuidString,
            kind: .mac,
            pairedAt: firstPairedAt,
            lastSeenAt: lastSeenAt,
            alias: alias,
            hostname: name,
            lastHost: lastHost,
            engineMachineId: nil,
            theyOS: TheyOSSnapshot(),
            apiEndpoint: nil,
            bootstrapEndpoint: nil,
            presencePort: presencePort,
            attachPort: attachPort,
            role: nil,
            sessionExpiresAt: nil
        )
    }
}
