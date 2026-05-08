import Foundation
import SoyehtCore
import os

private let pairingLogger = Logger(subsystem: "com.soyeht.mac", category: "pairing")

public struct PairedDevice: Codable, Sendable, Identifiable {
    public var id: UUID { deviceID }
    public let deviceID: UUID
    public var name: String
    public var model: String
    public let firstPairedAt: Date
    public var lastSeenAt: Date
}

@MainActor
final class PairingStore {
    static let shared = PairingStore()

    private enum DefaultsKey {
        static let macID            = "com.soyeht.mac.macId"
        static let pairedDevices    = "com.soyeht.mac.pairedDevices"
        static let revokedDevices   = "com.soyeht.mac.revokedDevices"
        static let macDisplayName   = "com.soyeht.mac.macDisplayName"
    }

    private enum KeychainAccount {
        static func secret(deviceID: UUID) -> String {
            "pairing_secret.\(deviceID.uuidString.lowercased())"
        }
    }

    private static let denyListTTL: TimeInterval = 30 * 24 * 3600

    private let defaults: UserDefaults
    private let keychain: KeychainHelper
    private let clock: () -> Date

    private(set) var macID: UUID
    private(set) var devices: [PairedDevice] = []
    private var denyList: [UUID: Date] = [:]

    /// Callback fired on any mutation — UI observes to reload.
    var onChange: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainHelper = KeychainHelper(
            service: "com.soyeht.mac",
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        ),
        clock: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.clock = clock
        self.macID = Self.loadOrCreateMacID(defaults: defaults)
        self.devices = Self.loadDevices(defaults: defaults)
        self.denyList = Self.loadDenyList(defaults: defaults)
        pruneDenyList()
        pairingLogger.log("store_init mac_id=\(self.macID.uuidString, privacy: .public) paired=\(self.devices.count, privacy: .public) revoked=\(self.denyList.count, privacy: .public)")
    }

    var macName: String {
        if let custom = defaults.string(forKey: DefaultsKey.macDisplayName),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return Host.current().localizedName ?? "Mac"
    }

    /// Called from Preferences when the user edits the display name field.
    /// Empty string clears the override (falls back to `Host.current().localizedName`).
    func setMacDisplayName(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.macDisplayName)
        } else {
            defaults.set(trimmed, forKey: DefaultsKey.macDisplayName)
        }
        pairingLogger.log("mac_display_name_changed empty=\(trimmed.isEmpty, privacy: .public)")
        onChange?()
    }

    // MARK: - Lookup

    func secret(for deviceID: UUID) -> Data? {
        guard let base64 = keychain.loadString(account: KeychainAccount.secret(deviceID: deviceID)) else {
            return nil
        }
        return PairingCrypto.base64URLDecode(base64)
    }

    func isPaired(deviceID: UUID) -> Bool {
        devices.contains { $0.deviceID == deviceID } && secret(for: deviceID) != nil
    }

    func device(id: UUID) -> PairedDevice? {
        devices.first(where: { $0.deviceID == id })
    }

    func isRevoked(deviceID: UUID) -> Bool {
        denyList[deviceID] != nil
    }

    // MARK: - Pair / Resume

    /// Generates a new shared secret, persists device metadata + secret, returns secret bytes.
    func pair(deviceID: UUID, name: String, model: String) -> Data {
        let secret = PairingCrypto.randomBytes(count: 32)
        let base64 = PairingCrypto.base64URLEncode(secret)
        keychain.save(Data(base64.utf8), account: KeychainAccount.secret(deviceID: deviceID))

        let now = clock()
        if let idx = devices.firstIndex(where: { $0.deviceID == deviceID }) {
            devices[idx].name = name
            devices[idx].model = model
            devices[idx].lastSeenAt = now
        } else {
            devices.append(PairedDevice(
                deviceID: deviceID,
                name: name,
                model: model,
                firstPairedAt: now,
                lastSeenAt: now
            ))
        }
        // Re-pair removes stale revocation.
        denyList.removeValue(forKey: deviceID)
        persistDevices()
        persistDenyList()
        pairingLogger.log("pair_persisted device_id=\(deviceID.uuidString, privacy: .public) name=\(name, privacy: .public) model=\(model, privacy: .public)")
        onChange?()
        return secret
    }

    func updateLastSeen(deviceID: UUID) {
        guard let idx = devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        devices[idx].lastSeenAt = clock()
        persistDevices()
        onChange?()
    }

    func rename(deviceID: UUID, to newName: String) {
        guard let idx = devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        devices[idx].name = newName
        persistDevices()
        onChange?()
    }

    // MARK: - Revocation

    @discardableResult
    func revoke(deviceID: UUID) -> Bool {
        let existed = devices.contains { $0.deviceID == deviceID }
        devices.removeAll { $0.deviceID == deviceID }
        keychain.delete(account: KeychainAccount.secret(deviceID: deviceID))
        denyList[deviceID] = clock()
        persistDevices()
        persistDenyList()
        pairingLogger.log("device_revoked device_id=\(deviceID.uuidString, privacy: .public) existed=\(existed, privacy: .public)")
        onChange?()
        return existed
    }

    func revokeAll() {
        let all = devices.map(\.deviceID)
        let now = clock()
        for id in all {
            keychain.delete(account: KeychainAccount.secret(deviceID: id))
            denyList[id] = now
        }
        devices.removeAll()
        persistDevices()
        persistDenyList()
        pairingLogger.log("all_devices_revoked count=\(all.count, privacy: .public)")
        onChange?()
    }

    func pruneDenyList() {
        let cutoff = clock().addingTimeInterval(-Self.denyListTTL)
        let before = denyList.count
        denyList = denyList.filter { _, revokedAt in revokedAt >= cutoff }
        if denyList.count != before {
            persistDenyList()
            pairingLogger.log("deny_list_pruned removed=\(before - self.denyList.count, privacy: .public)")
        }
    }

    // MARK: - Persistence

    private func persistDevices() {
        if let data = try? JSONEncoder.pairingISO.encode(devices) {
            defaults.set(data, forKey: DefaultsKey.pairedDevices)
        }
    }

    private func persistDenyList() {
        let entries = denyList.map { RevokedDeviceEntry(deviceId: $0.key, revokedAt: $0.value) }
        do {
            let data = try JSONEncoder.pairingISO.encode(entries)
            defaults.set(data, forKey: DefaultsKey.revokedDevices)
        } catch {
            pairingLogger.error(
                "deny-list encode failed; not persisting. error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func loadOrCreateMacID(defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: DefaultsKey.macID),
           let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: DefaultsKey.macID)
        pairingLogger.log("mac_id_generated mac_id=\(id.uuidString, privacy: .public)")
        return id
    }

    private static func loadDevices(defaults: UserDefaults) -> [PairedDevice] {
        guard let data = defaults.data(forKey: DefaultsKey.pairedDevices),
              let list = try? JSONDecoder.pairingISO.decode([PairedDevice].self, from: data) else {
            return []
        }
        return list
    }

    /// Wire shape for a single deny-list entry.
    ///
    /// Persisted as part of an array of these dicts under
    /// `DefaultsKey.revokedDevices`. Encoded via `JSONEncoder.pairingISO`
    /// (which sets `dateEncodingStrategy = .iso8601`), so the on-disk
    /// format is `[{"device_id": "<uuid>", "revoked_at": "<iso8601>"}]`
    /// — structurally equivalent to the previous hand-rolled
    /// `JSONSerialization` format with
    /// `ISO8601DateFormatter([.withInternetDateTime])` and decodes
    /// identically. Note that "byte-identical" overstates the contract:
    /// `JSONSerialization` does not guarantee map-key ordering across
    /// invocations, and `JSONEncoder` with default `outputFormatting`
    /// likewise does not sort keys, so two encodes of the same dict can
    /// produce different byte sequences. What matters for migration is
    /// that the new decoder reads what the old encoder wrote — that
    /// holds. Codable audit 2026-05-08 P1.
    ///
    /// TODO(codable-audit-followup): wire-format equivalence test for
    /// `loadDenyList` is deferred — `SoyehtMacDomainTests` does not
    /// currently symlink `PairingStore.swift`, so adding test coverage
    /// requires expanding that target's source set. The test should
    /// (a) write a fixed `[[String: String]]` array via
    /// `JSONSerialization.data(withJSONObject:)` with the legacy
    /// formatter and decode via `JSONDecoder.pairingISO` to assert the
    /// migration story, and (b) round-trip a `RevokedDeviceEntry`
    /// through `JSONEncoder.pairingISO` and re-decode via the legacy
    /// path to assert bidirectional compatibility.
    private struct RevokedDeviceEntry: Codable, Sendable {
        let deviceId: UUID
        let revokedAt: Date

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case revokedAt = "revoked_at"
        }
    }

    private static func loadDenyList(defaults: UserDefaults) -> [UUID: Date] {
        guard let data = defaults.data(forKey: DefaultsKey.revokedDevices) else {
            return [:]
        }
        let entries: [RevokedDeviceEntry]
        do {
            entries = try JSONDecoder.pairingISO.decode([RevokedDeviceEntry].self, from: data)
        } catch {
            // Failure mode is stricter than the previous hand-rolled
            // path: any single malformed entry now zeroes the entire
            // deny-list (Codable's array decode is all-or-nothing),
            // whereas the legacy `JSONSerialization` + per-entry parse
            // used to keep the good entries and skip bad ones. This is
            // intentional — the legacy behaviour silently lost
            // information about which entries failed, masking on-disk
            // schema drift. A revoked device that re-appears as
            // un-revoked is a strict security regression direction (a
            // device the operator already rejected becomes acceptable
            // again), so the audit signal is more important than the
            // partial-recovery convenience. The breadcrumb lets a
            // future audit notice when on-disk data drifts from the
            // current schema. Codable audit 2026-05-08 P1.
            pairingLogger.error(
                "deny-list decode failed; resetting to empty. error=\(String(describing: error), privacy: .public)"
            )
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.deviceId, $0.revokedAt) })
    }
}

extension JSONEncoder {
    static let pairingISO: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let pairingISO: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
