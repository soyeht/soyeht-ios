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
        let pairs: [[String: String]] = denyList.map { key, value in
            [
                "device_id": key.uuidString,
                "revoked_at": Self.iso(value),
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: pairs) {
            defaults.set(data, forKey: DefaultsKey.revokedDevices)
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

    private static func loadDenyList(defaults: UserDefaults) -> [UUID: Date] {
        guard let data = defaults.data(forKey: DefaultsKey.revokedDevices),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return [:]
        }
        var out: [UUID: Date] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        for dict in arr {
            if let idStr = dict["device_id"], let id = UUID(uuidString: idStr),
               let dateStr = dict["revoked_at"], let date = iso.date(from: dateStr) {
                out[id] = date
            }
        }
        return out
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
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
