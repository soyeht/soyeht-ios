import Foundation

/// This iPhone/iPad as an owner/admin device in the Soyeht model.
///
/// Always available — even before a Soyeht identity exists locally.
/// The setup-invitation flow (Caso B) needs `displayName`,
/// `localPairingDeviceId`, and `model` to publish before any tenant
/// is paired, so this type is never optional and never gated on
/// `SoyehtIdentity.state`.
///
/// Why the verbose `localPairingDeviceId` name: the underlying value
/// is `PairedMacsStore.ensureDeviceID()` — a Keychain-backed UUID used
/// to key `pairing_secret.{macID}` and to identify this iPhone in
/// `MacPresenceClient` WebSocket sessions. It is a *local pairing
/// identity*, not a protocol-level device cert id. When DeviceCert
/// (`d_id`) lands on the wire, it gets its own field on this struct;
/// the two ids must not collapse.
struct OwnerDevice: Equatable, Sendable {
    /// UUID used as the iPhone's identity in legacy pair-with-Mac
    /// flows. Stable across app launches via Keychain
    /// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — backup
    /// restore to a different iPhone forces a new id and re-pair).
    /// Not the same as DeviceCert `d_id`.
    let localPairingDeviceId: UUID

    /// User-visible name from `UIDevice.current.name`. On iOS 16+ this
    /// is generic ("iPhone") unless the app has the
    /// `com.apple.developer.device-information.user-assigned-device-name`
    /// entitlement — the existing setup-invitation code already treats
    /// it as best-effort, so we mirror that here without special-casing.
    let displayName: String

    /// Hardware identifier (e.g. `"iPhone15,2"`) from `uname(2)`. More
    /// useful for diagnostics than `UIDevice.current.localizedModel`,
    /// which collapses every iPhone to `"iPhone"`.
    let model: String

    /// Always `true` for the value `SoyehtIdentity.thisDevice` returns.
    /// Reserved for future multi-owner-device topologies (e.g.
    /// listing all iPhones/iPads under a single owner — PR-5 / R1).
    let isThisDevice: Bool
}
