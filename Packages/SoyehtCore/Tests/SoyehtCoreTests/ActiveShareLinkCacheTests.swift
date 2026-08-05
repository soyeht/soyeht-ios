import CryptoKit
import Foundation
import Security
import Testing

@testable import SoyehtCore

/// In-memory stand-in for the Keychain database: `service -> account -> value`,
/// exactly the scoping `kSecAttrService` gives a real query.
///
/// `KeychainHelper.allAccounts`/`delete` are deliberately DP-keychain-only
/// (the legacy-login-keychain fallback `save`/`load` use on macOS is one-way by
/// design — widening it to make `swift test` pass on this host would risk
/// ACL/prompt behaviour for every OTHER `KeychainHelper` caller, e.g.
/// `PairedMacsStore`). `SoyehtCoreTests` also has no reachable iOS-simulator
/// path: `Soyeht.xcscheme`'s `TestAction` lists only `SoyehtTests`. So the real
/// Keychain cannot be exercised here.
///
/// What changed, and why it matters: an earlier version of this file worked
/// around that by having a *second cache implementation* mirror the real
/// keying. That is precisely a test which re-implements the caller, and it
/// could not catch the caller — deleting `purgeLegacyAccounts()` from the real
/// `store` left every test green. Now the fake stops at the Keychain boundary
/// and every test drives the REAL `KeychainActiveShareLinkCache`.
private final class FakeKeychainStore: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String: [String: String]] = [:]
  /// Every account string the backing was handed, on ANY operation. Dictionary
  /// keys alone are not enough: `load` and `delete` pass an account through
  /// without leaving one behind, and those are exactly the calls where a raw
  /// slot id could still reach a real Keychain.
  private var observedAccounts: [String] = []

  func save(_ value: String, service: String, account: String) {
    lock.lock()
    defer { lock.unlock() }
    observedAccounts.append(account)
    entries[service, default: [:]][account] = value
  }

  func load(service: String, account: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    observedAccounts.append(account)
    return entries[service]?[account]
  }

  func delete(service: String, account: String) {
    lock.lock()
    defer { lock.unlock() }
    observedAccounts.append(account)
    entries[service]?.removeValue(forKey: account)
  }

  func accounts(service: String) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return Array(entries[service]?.keys ?? [String: String]().keys)
  }

  // MARK: - Test-only inspection (never recorded as backing traffic)

  /// Plants an entry the way an older build would have left it, without
  /// counting as an observed account.
  func seedRaw(_ value: String, service: String, account: String) {
    lock.lock()
    defer { lock.unlock() }
    entries[service, default: [:]][account] = value
  }

  /// Non-recording read, so assertions never pollute `accountsEverSeen()`.
  func peek(service: String, account: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return entries[service]?[account]
  }

  func legacyAccountCount(service: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return (entries[service]?.keys ?? [String: String]().keys)
      .filter { !KeychainActiveShareLinkCache.isCurrentFormatAccount($0) }
      .count
  }

  func accountsEverSeen() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return observedAccounts
  }
}

/// Stops at the Keychain boundary: it implements the four calls the cache
/// makes and nothing else. It contains no account derivation, no purge rule
/// and no prune rule — all of that stays in the type under test.
private struct FakeKeychainBacking: ActiveShareLinkKeychainBacking {
  let store: FakeKeychainStore
  let service: String
  let accessibility: String = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

  @discardableResult
  func saveString(_ value: String, account: String) -> Bool {
    store.save(value, service: service, account: account)
    return true
  }

  func loadString(account: String) -> String? {
    store.load(service: service, account: account)
  }

  func delete(account: String) {
    store.delete(service: service, account: account)
  }

  func allAccounts() -> [String] {
    store.accounts(service: service)
  }
}

@Suite("ActiveShareLinkCache")
struct ActiveShareLinkCacheTests {

  private static let testService = "svc"

  /// The REAL cache, pointed at an in-memory backing.
  private func makeCache(
    store: FakeKeychainStore,
    service: String = testService
  ) -> KeychainActiveShareLinkCache {
    KeychainActiveShareLinkCache(keychain: FakeKeychainBacking(store: store, service: service))
  }

  private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  /// Exactly what an older build wrote: the raw 16-byte slot id as 32 hex chars.
  private func legacyAccount(for slotID: Data) -> String { hex(slotID) }

  // MARK: - Store / load / remove / prune, against the real type

  @Test func storeThenUriRoundTripsForTheSameSlot() {
    let cache = makeCache(store: FakeKeychainStore())
    let slotId = Data(repeating: 0x01, count: 16)

    let stored = cache.store(uri: "soyeht://claw-share/v1?e=abc", forSlotID: slotId)

    #expect(stored)
    #expect(cache.uri(forSlotID: slotId) == "soyeht://claw-share/v1?e=abc")
  }

  @Test func uriIsNilForAnUncachedSlot() {
    let cache = makeCache(store: FakeKeychainStore())
    #expect(cache.uri(forSlotID: Data(repeating: 0x02, count: 16)) == nil)
  }

  @Test func removeDeletesOnlyTheNamedSlot() {
    let cache = makeCache(store: FakeKeychainStore())
    let keep = Data(repeating: 0x03, count: 16)
    let drop = Data(repeating: 0x04, count: 16)
    cache.store(uri: "soyeht://claw-share/v1?e=keep", forSlotID: keep)
    cache.store(uri: "soyeht://claw-share/v1?e=drop", forSlotID: drop)

    cache.remove(forSlotID: drop)

    #expect(cache.uri(forSlotID: keep) == "soyeht://claw-share/v1?e=keep")
    #expect(cache.uri(forSlotID: drop) == nil)
  }

  @Test func pruneKeepsOnlyTheNamedSlotsAndDropsEverythingElse() {
    let cache = makeCache(store: FakeKeychainStore())
    let waiting1 = Data(repeating: 0x05, count: 16)
    let waiting2 = Data(repeating: 0x06, count: 16)
    let noLongerWaiting = Data(repeating: 0x07, count: 16)
    let absentFromList = Data(repeating: 0x08, count: 16)
    cache.store(uri: "soyeht://claw-share/v1?e=w1", forSlotID: waiting1)
    cache.store(uri: "soyeht://claw-share/v1?e=w2", forSlotID: waiting2)
    cache.store(uri: "soyeht://claw-share/v1?e=gone1", forSlotID: noLongerWaiting)
    cache.store(uri: "soyeht://claw-share/v1?e=gone2", forSlotID: absentFromList)

    cache.prune(keeping: [waiting1, waiting2])

    #expect(cache.uri(forSlotID: waiting1) != nil, "kept slot must survive")
    #expect(cache.uri(forSlotID: waiting2) != nil, "kept slot must survive")
    #expect(cache.uri(forSlotID: noLongerWaiting) == nil, "converged-away slot must be pruned")
    #expect(cache.uri(forSlotID: absentFromList) == nil, "slot missing from the list must be pruned")
  }

  @Test func pruneNeverReachesAnotherService() {
    // Two real caches over ONE store but different service strings — exactly
    // what two `KeychainActiveShareLinkCache`es on different services are,
    // since every real query is scoped by `kSecAttrService`.
    let shared = FakeKeychainStore()
    let target = makeCache(store: shared, service: "target")
    let other = makeCache(store: shared, service: "other")
    let sharedSlotIdBytes = Data(repeating: 0x09, count: 16)

    target.store(uri: "soyeht://claw-share/v1?e=target", forSlotID: sharedSlotIdBytes)
    other.store(uri: "soyeht://claw-share/v1?e=other", forSlotID: sharedSlotIdBytes)

    // The most aggressive call available: keep nothing.
    target.prune(keeping: [])

    #expect(target.uri(forSlotID: sharedSlotIdBytes) == nil, "target's own entry must be pruned")
    #expect(
      other.uri(forSlotID: sharedSlotIdBytes) == "soyeht://claw-share/v1?e=other",
      "a different service's entry, even for the SAME slot id, must survive untouched"
    )
  }

  // MARK: - Account derivation: irreversible, domain-separated

  /// Replaces an earlier test that asserted `account == "deadbeef"` — i.e. one
  /// that pinned the defect. `slot_id` is the claim capability (anonymous
  /// claim + CAS server-side), so a reversible `kSecAttrAccount` put a
  /// capability into queryable metadata.
  @Test func accountIsNotReversibleToTheSlotId() {
    let slotId = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let rawHex = hex(slotId)

    let account = KeychainActiveShareLinkCache.account(forSlotID: slotId)

    #expect(account != rawHex)
    #expect(!account.contains(rawHex), "the raw slot hex must not survive anywhere inside the account")
    #expect(account != "deadbeef", "explicit non-regression against the exact previous scheme")
    #expect(!account.contains("soyeht"), "the account must never encode the URI or the domain label verbatim")
  }

  /// Pins the derivation against a digest recomputed independently here —
  /// deliberately not by calling the type under test, which would only prove
  /// it equals itself.
  @Test func accountPinsTheDomainSeparatedDigest() {
    let slotId = Data(repeating: 0xAB, count: 16)

    var material = Data("soyeht.claw-share.active-share-link.v1".utf8)
    material.append(0)
    material.append(slotId)
    let expected = hex(Data(SHA256.hash(data: material)))

    #expect(KeychainActiveShareLinkCache.account(forSlotID: slotId) == expected)
  }

  /// Without the separator, `label ‖ slot` could be reproduced by a different
  /// (label, slot) split. The `0x00` is what makes the split unambiguous, so
  /// dropping it must change the digest.
  @Test func domainSeparatorActuallyParticipatesInTheDigest() {
    let slotId = Data(repeating: 0x07, count: 16)

    var withoutSeparator = Data("soyeht.claw-share.active-share-link.v1".utf8)
    withoutSeparator.append(slotId)
    let unseparated = hex(Data(SHA256.hash(data: withoutSeparator)))

    #expect(KeychainActiveShareLinkCache.account(forSlotID: slotId) != unseparated)
  }

  @Test func accountIsDeterministicAndInjective() {
    let a = Data(repeating: 0x01, count: 16)
    let b = Data(repeating: 0x02, count: 16)

    #expect(
      KeychainActiveShareLinkCache.account(forSlotID: a)
        == KeychainActiveShareLinkCache.account(forSlotID: a), "must be deterministic")
    #expect(
      KeychainActiveShareLinkCache.account(forSlotID: a)
        != KeychainActiveShareLinkCache.account(forSlotID: b), "distinct slots must not collide")
  }

  /// The fixed width is what lets `isCurrentFormatAccount` detect legacy
  /// entries without assuming how long a slot id is.
  @Test func accountIsFixedWidthLowercaseHexRegardlessOfSlotLength() {
    for slotId in [Data([0xDE, 0xAD, 0xBE, 0xEF]), Data(repeating: 0x5A, count: 16), Data()] {
      let account = KeychainActiveShareLinkCache.account(forSlotID: slotId)
      #expect(account.count == KeychainActiveShareLinkCache.accountLength)
      #expect(account.allSatisfy { "0123456789abcdef".contains($0) })
      #expect(KeychainActiveShareLinkCache.isCurrentFormatAccount(account))
    }
  }

  @Test func legacyRawHexAccountsAreNotMistakenForCurrentFormat() {
    #expect(!KeychainActiveShareLinkCache.isCurrentFormatAccount(
      legacyAccount(for: Data(repeating: 0xAB, count: 16))))
    #expect(!KeychainActiveShareLinkCache.isCurrentFormatAccount("deadbeef"))
    #expect(
      !KeychainActiveShareLinkCache.isCurrentFormatAccount(String(repeating: "A", count: 64)),
      "uppercase is not what this derivation emits")
    #expect(
      !KeychainActiveShareLinkCache.isCurrentFormatAccount(String(repeating: "z", count: 64)),
      "right width, wrong alphabet")
  }

  // MARK: - The backing never receives slot material

  /// Across EVERY operation, no account string handed to the Keychain backing
  /// carries the slot id — neither as hex nor as raw bytes.
  @Test func backingNeverReceivesSlotBytesOrHex() {
    let store = FakeKeychainStore()
    let cache = makeCache(store: store)
    let slotId = Data(repeating: 0xAB, count: 16)
    let rawHex = hex(slotId)

    cache.store(uri: "soyeht://claw-share/v1?e=abc", forSlotID: slotId)
    _ = cache.uri(forSlotID: slotId)
    cache.remove(forSlotID: slotId)
    cache.prune(keeping: [slotId])

    let seen = store.accountsEverSeen()
    #expect(!seen.isEmpty, "guard against a vacuous pass if no operation reached the backing")
    for account in seen {
      #expect(!account.lowercased().contains(rawHex), "slot hex reached the backing in account: \(account)")
      #expect(
        !Data(account.utf8).contains(slotId), "raw slot bytes reached the backing in account: \(account)")
    }
  }

  // MARK: - Legacy migration, driven through the real type

  @Test func pruneRemovesLegacyFormatAccounts() {
    let store = FakeKeychainStore()
    let cache = makeCache(store: store)
    let live = Data(repeating: 0x01, count: 16)
    let legacy = legacyAccount(for: Data(repeating: 0xAB, count: 16))
    cache.store(uri: "soyeht://claw-share/v1?e=live", forSlotID: live)
    store.seedRaw("soyeht://claw-share/v1?e=legacy", service: Self.testService, account: legacy)

    #expect(store.legacyAccountCount(service: Self.testService) == 1, "precondition")

    cache.prune(keeping: [live])

    #expect(
      store.peek(service: Self.testService, account: legacy) == nil,
      "a pre-digest account can never be in the keep-set, so prune must delete it")
    #expect(store.legacyAccountCount(service: Self.testService) == 0)
    #expect(cache.uri(forSlotID: live) != nil, "the live slot must survive")
  }

  /// The owner who mints but never opens Active Shares: `prune` never fires, so
  /// `store` is the only chance to clear raw slot ids off the device. Counts the
  /// real legacy account before and after, so removing `purgeLegacyAccounts()`
  /// from `store` fails on an assertion rather than on a technicality.
  @Test func storePurgesLegacyAccountsEvenWhenPruneNeverRuns() {
    let store = FakeKeychainStore()
    let cache = makeCache(store: store)
    let legacy = legacyAccount(for: Data(repeating: 0xAB, count: 16))
    let fresh = Data(repeating: 0x02, count: 16)
    store.seedRaw("soyeht://claw-share/v1?e=legacy", service: Self.testService, account: legacy)

    #expect(
      store.legacyAccountCount(service: Self.testService) == 1,
      "precondition: exactly one raw-slot-id account exists before the store")
    #expect(store.peek(service: Self.testService, account: legacy) != nil)

    cache.store(uri: "soyeht://claw-share/v1?e=fresh", forSlotID: fresh)

    #expect(
      store.legacyAccountCount(service: Self.testService) == 0,
      "store must purge every raw-slot-id account, even though prune never ran")
    #expect(store.peek(service: Self.testService, account: legacy) == nil)
    #expect(cache.uri(forSlotID: fresh) != nil, "the freshly minted link must still be cached")
  }

  // MARK: - Real backend, structural only (no Keychain I/O — see the type doc above)

  @Test func productionCacheUsesAnIsolatedServicePerProfileAndDeviceOnlyAccessibility() {
    let release = KeychainActiveShareLinkCache(profile: .release)
    let dev = KeychainActiveShareLinkCache(profile: .dev)

    #expect(
      release.keychain.service
        == "\(SoyehtInstallProfile.release.mobileKeychainService).claw-share.active-share-link")
    #expect(
      dev.keychain.service
        == "\(SoyehtInstallProfile.dev.mobileKeychainService).claw-share.active-share-link")
    #expect(release.keychain.service != dev.keychain.service, "release and dev must never share a keychain service")

    let expectedAccessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    #expect(release.keychain.accessibility == expectedAccessibility)
    #expect(dev.keychain.accessibility == expectedAccessibility)
  }
}
