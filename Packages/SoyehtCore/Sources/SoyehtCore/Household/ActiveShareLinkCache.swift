import CryptoKit
import Foundation
import Security

/// Local-only cache of a minted share's bearer link, keyed by `slotId`.
///
/// The link is never persisted anywhere else — not the mesh log (it would
/// put a bearer capability at rest on every household machine, permanently,
/// immune to server-side deletion), not the server (the slot store is
/// in-memory and the wire deliberately omits it), not `UserDefaults`, plain
/// disk, or any log. Only the minting device can Copy Link; a reinstall or a
/// different owner device legitimately has none — `list`/`revoke` keep
/// working regardless, since the cache is a convenience, never an
/// authority.
public protocol ActiveShareLinkCaching: Sendable {
  /// Returns whether the write actually persisted. A `false` here means
  /// exactly what an absent cache means everywhere else in this type: no
  /// future Copy Link can be promised for this slot. Callers must never log
  /// or otherwise surface the `uri` itself on failure — only that a failure
  /// happened.
  @discardableResult
  func store(uri: String, forSlotID slotID: Data) -> Bool
  func uri(forSlotID slotID: Data) -> String?
  func remove(forSlotID slotID: Data)
  /// Deletes every cached entry EXCEPT the given slots. Called after a
  /// successful list refresh with the set of currently-Waiting,
  /// not-yet-expired slot ids — a slot that converged to Accepted/Expired/
  /// Revoked, or that no longer appears in the list at all, is pruned by
  /// simply not being in `keepSlotIDs`.
  func prune(keeping keepSlotIDs: Set<Data>)
}

/// The exact Keychain surface this cache uses — nothing more. It exists so
/// tests can drive the REAL `KeychainActiveShareLinkCache` against an
/// in-memory backing instead of re-implementing its logic in a parallel fake.
/// That distinction is not cosmetic: a fake that mirrors the type under test
/// cannot catch a change in the type under test, and a mutation deleting the
/// `purgeLegacyAccounts()` call from `store` provably survived while such a
/// mirror was the only coverage.
///
/// `KeychainHelper` satisfies this as-is (empty conformance below) — no
/// production behaviour moves to accommodate the seam.
protocol ActiveShareLinkKeychainBacking: Sendable {
  var service: String { get }
  var accessibility: String { get }
  @discardableResult
  func saveString(_ value: String, account: String) -> Bool
  func loadString(account: String) -> String?
  func delete(account: String)
  func allAccounts() -> [String]
}

extension KeychainHelper: ActiveShareLinkKeychainBacking {}

public struct KeychainActiveShareLinkCache: ActiveShareLinkCaching {
  /// Not `private`: `@testable import` needs to inspect `service`/
  /// `accessibility` structurally (see `ActiveShareLinkCacheTests`) — real
  /// Keychain I/O isn't exercised in that check, only that this type is
  /// configured the way it claims to be.
  let keychain: any ActiveShareLinkKeychainBacking

  public init(profile: SoyehtInstallProfile = .current) {
    self.init(keychain: KeychainHelper(
      service: Self.service(for: profile),
      accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ))
  }

  /// Not `public`: reachable only via `@testable import` — lets tests point
  /// this type at an in-memory backing (or at a disposable, uniquely-suffixed
  /// real service) so every test exercises the real store/uri/remove/prune
  /// logic rather than a copy of it.
  init(keychain: any ActiveShareLinkKeychainBacking) {
    self.keychain = keychain
  }

  /// Isolated from every other keychain use in the app (paired-Mac secrets,
  /// the member identity key, session tokens, ...) and from the other
  /// install profile (Dev vs prod never share a service string), same
  /// pattern as `SecureEnclaveClawShareMemberIdentityProvider`.
  static func service(for profile: SoyehtInstallProfile) -> String {
    "\(profile.mobileKeychainService).claw-share.active-share-link"
  }

  /// Domain-separation label for the account digest. The trailing `0x00`
  /// keeps the label unambiguously separated from the slot bytes that follow,
  /// same construction as `OwnerApprovalContextV2DTO.challengeDomain`. The
  /// `.v1` suffix exists so a future change of derivation is a new domain
  /// rather than a silent collision with entries written by this one.
  private static let accountDomain = Data("soyeht.claw-share.active-share-link.v1".utf8) + Data([0])

  /// Every account this derivation produces is exactly this many characters.
  static let accountLength = 64

  private static let lowercaseHexDigits = Set("0123456789abcdef")

  /// `hexLower(SHA256(domain || 0x00 || slot_id))` — deliberately NOT the raw
  /// slot id, and deliberately not reversible.
  ///
  /// `slot_id` is a **claim capability, not an identifier**: `POST
  /// /api/v1/claw-share/claim` is anonymous, and the engine only verifies the
  /// guest's own self-generated signature before CAS-consuming the slot by
  /// `slot_id`. So whoever holds those 16 bytes can consume the share. A
  /// Keychain `kSecAttrAccount` is queryable metadata rather than the
  /// protected value, so storing the raw slot id there put a capability in
  /// the weaker half of the item.
  ///
  /// Be precise about what this buys: the digest protects only the
  /// **metadata**. The stored *value* is the invite URI, which necessarily
  /// still contains the `slot_id` — that is the whole point of caching it,
  /// and values are the encrypted half. Recovering a capability now requires
  /// decrypting the value instead of merely enumerating attributes.
  ///
  /// Unkeyed SHA-256 is sufficient here and an HMAC would be worse: the slot
  /// id is 16 CSPRNG bytes, so enumeration and precomputation are infeasible
  /// at 128 bits, whereas an HMAC key would have to live in this same
  /// Keychain — circular, for no attacker it defeats.
  static func account(forSlotID slotID: Data) -> String {
    var material = accountDomain
    material.append(slotID)
    return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
  }

  /// Whether an account string was written by the current derivation. Used to
  /// find pre-digest ("legacy") entries, which held the raw slot id hex and
  /// must be deleted wherever we encounter them. Keyed on the fixed digest
  /// width rather than on the legacy width, so it carries no assumption about
  /// how long a slot id is.
  static func isCurrentFormatAccount(_ account: String) -> Bool {
    account.count == accountLength && account.allSatisfy(lowercaseHexDigits.contains)
  }

  /// Deletes every entry in this service whose account is not in the current
  /// digest format — i.e. every account that still encodes a raw slot id.
  /// Their cached links are lost (the owner must revoke and re-mint to hand
  /// out a link again), which is the safe direction: this cache is a
  /// convenience, never an authority.
  private func purgeLegacyAccounts() {
    for account in keychain.allAccounts() where !Self.isCurrentFormatAccount(account) {
      keychain.delete(account: account)
    }
  }

  @discardableResult
  public func store(uri: String, forSlotID slotID: Data) -> Bool {
    // Minting is the one moment we are guaranteed to touch this service even
    // if the owner never opens Active Shares, so it is where the legacy sweep
    // has to happen too — `prune` alone would leave raw slot ids sitting in
    // the metadata of a device whose owner only ever mints.
    purgeLegacyAccounts()
    return keychain.saveString(uri, account: Self.account(forSlotID: slotID))
  }

  public func uri(forSlotID slotID: Data) -> String? {
    keychain.loadString(account: Self.account(forSlotID: slotID))
  }

  public func remove(forSlotID slotID: Data) {
    keychain.delete(account: Self.account(forSlotID: slotID))
  }

  public func prune(keeping keepSlotIDs: Set<Data>) {
    let keepAccounts = Set(keepSlotIDs.map(Self.account(forSlotID:)))
    // A single enumeration does both jobs. Legacy accounts are purged here by
    // construction rather than by a second pass: `keepAccounts` is built from
    // the current derivation, so a raw-slot-id account can never be a member
    // of it and is always deleted. That is load-bearing for the migration,
    // not an incidental side effect — `pruneRemovesLegacyFormatAccounts`
    // pins it.
    for account in keychain.allAccounts() where !keepAccounts.contains(account) {
      keychain.delete(account: account)
    }
  }
}
