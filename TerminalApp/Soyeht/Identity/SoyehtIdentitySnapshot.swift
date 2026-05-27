import Foundation
import SoyehtCore

/// Read-only view over an `ActiveHouseholdState`, exposed with
/// vocabulary the UI can use without leaking the word "household".
///
/// Storage is unchanged: the underlying `ActiveHouseholdState` lives
/// in the Keychain via `HouseholdSessionStore`. This type is a thin
/// wrapper around the raw value — it does not copy fields, does not
/// add fields, and does not transform anything. When a view needs a
/// new piece of data exposed (e.g. `personCert.allows(...)`), the
/// accessor goes here, not on `ActiveHouseholdState`.
///
/// Deliberately not `Codable`. Persistence remains the responsibility
/// of `HouseholdSessionStore` against the raw `ActiveHouseholdState`.
struct SoyehtIdentitySnapshot: Equatable, Sendable {
    /// The underlying protocol-level identity. Views NEVER touch this
    /// — it is `internal` for the orchestrators in `Household/*` that
    /// still take `ActiveHouseholdState` as their parameter (e.g.
    /// `HouseholdSignMachineCertClient`, `HouseholdMachineJoinRuntime`).
    /// The single escape hatch from facade-vocabulary back to
    /// protocol-vocabulary.
    let raw: ActiveHouseholdState

    init(raw: ActiveHouseholdState) {
        self.raw = raw
    }

    /// Stable identifier for this Soyeht. Maps to `householdId` on the
    /// wire. UI should not assume any specific encoding — treat as
    /// an opaque string.
    var id: String { raw.householdId }

    /// User-facing label (e.g. "Caio's Home"). Maps to `householdName`
    /// on the wire. Empty string is technically valid; views that need
    /// a fallback should provide one at the call site.
    var displayName: String { raw.householdName }

    /// Engine endpoint that hosts the household state on the paired
    /// Mac/Linux. Used to construct `BootstrapPairDeviceURIClient`,
    /// `HouseholdSignMachineCertClient`, etc.
    var endpoint: URL { raw.endpoint }

    /// Stable identifier for the owning person (`person_id` on the
    /// wire). Same value across all this owner's devices.
    var ownerPersonId: String { raw.ownerPersonId }

    /// Display name from the owner's PersonCert. Set at first-pair time
    /// and updated by `HouseholdSessionController.refresh()` on Mac
    /// engine renames.
    var ownerPersonDisplayName: String { raw.personCert.displayName }

    /// When this device first paired into the Soyeht.
    var pairedAt: Date { raw.pairedAt }

    /// Last time the cached snapshot was refreshed from the engine.
    /// Optional because cold-start may have no fresh poll yet.
    var lastSeenAt: Date? { raw.lastSeenAt }

    /// True when the local identity is a delegated DeviceCert rather
    /// than the raw owner key (multi-owner-device topology).
    var isDelegatedDevice: Bool { raw.isDelegatedDevice }

    /// Underlying value for orquestradores `Household/*` que ainda
    /// recebem `ActiveHouseholdState`. Marked `internal` so SwiftUI
    /// views in the app target can also reach it when they pass the
    /// snapshot directly into an `HouseholdMachineJoinRuntime`-style
    /// API. NEW VIEWS should not introduce uses of `underlying` — the
    /// goal is for this escape hatch to shrink over time as the
    /// orchestrators are migrated.
    var underlying: ActiveHouseholdState { raw }

    /// PersonCert capability check (e.g. `allows("household.add_machine")`).
    /// Delegated rather than re-implemented so the cert format stays
    /// owned by `SoyehtCore`.
    func allows(_ operation: String) -> Bool {
        raw.personCert.allows(operation)
    }
}
