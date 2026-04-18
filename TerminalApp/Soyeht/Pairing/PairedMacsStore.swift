import Foundation
import SoyehtCore
import UIKit
import os

private let pairingLogger = Logger(subsystem: "com.soyeht.mobile", category: "pairing")

public struct PairedMac: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID { macID }
    public let macID: UUID
    public var name: String
    public var lastHost: String?
    public var presencePort: Int?
    public var attachPort: Int?
    public let firstPairedAt: Date
    public var lastSeenAt: Date
}

@MainActor
final class PairedMacsStore {
    static let shared = PairedMacsStore()

    private enum DefaultsKey {
        static let deviceID   = "com.soyeht.mobile.deviceId"
        static let pairedMacs = "com.soyeht.mobile.pairedMacs"
    }

    private enum KeychainAccount {
        static let deviceID = "device_id"
        static func secret(macID: UUID) -> String {
            "pairing_secret.\(macID.uuidString.lowercased())"
        }
    }

    private let defaults: UserDefaults
    private let keychain: KeychainHelper

    private(set) var macs: [PairedMac] = []

    var onChange: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainHelper = KeychainHelper(
            service: "com.soyeht.mobile",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.macs = Self.loadMacs(defaults: defaults)
    }

    // MARK: - Device identity (this iPhone)

    /// Generates (or returns) the stable device id used when talking to any Mac.
    /// Keychain backs it with `ThisDeviceOnly` so restoring a backup to a new
    /// phone forces a new pairing.
    @discardableResult
    func ensureDeviceID() -> UUID {
        if let raw = keychain.loadString(account: KeychainAccount.deviceID),
           let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        keychain.saveString(id.uuidString, account: KeychainAccount.deviceID)
        pairingLogger.log("device_id_generated device_id=\(id.uuidString, privacy: .public)")
        return id
    }

    var deviceID: UUID { ensureDeviceID() }

    var deviceName: String { UIDevice.current.name }

    /// Hardware identifier like "iPhone15,2" — more useful than
    /// `localizedModel` which just returns "iPhone" on all iPhones.
    var deviceModel: String {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? UIDevice.current.localizedModel : machine
    }

    // MARK: - Per-Mac secret

    func secret(for macID: UUID) -> Data? {
        guard let base64 = keychain.loadString(account: KeychainAccount.secret(macID: macID)) else {
            return nil
        }
        return PairingCrypto.base64URLDecode(base64)
    }

    func hasSecret(for macID: UUID) -> Bool {
        secret(for: macID) != nil
    }

    func storeSecret(_ secret: Data, for macID: UUID) {
        let base64 = PairingCrypto.base64URLEncode(secret)
        keychain.saveString(base64, account: KeychainAccount.secret(macID: macID))
        pairingLogger.log("pair_secret_stored mac_id=\(macID.uuidString, privacy: .public)")
    }

    // MARK: - Mac registry

    func upsertMac(macID: UUID, name: String, host: String?, presencePort: Int? = nil, attachPort: Int? = nil) {
        let now = Date()
        if let idx = macs.firstIndex(where: { $0.macID == macID }) {
            macs[idx].name = name
            macs[idx].lastSeenAt = now
            if let host { macs[idx].lastHost = host }
            if let presencePort { macs[idx].presencePort = presencePort }
            if let attachPort { macs[idx].attachPort = attachPort }
        } else {
            macs.append(PairedMac(
                macID: macID,
                name: name,
                lastHost: host,
                presencePort: presencePort,
                attachPort: attachPort,
                firstPairedAt: now,
                lastSeenAt: now
            ))
        }
        persist()
        onChange?()
    }

    func updateDisplayName(macID: UUID, name: String) {
        guard let idx = macs.firstIndex(where: { $0.macID == macID }) else { return }
        guard macs[idx].name != name else { return }
        macs[idx].name = name
        persist()
        onChange?()
    }

    func updateEndpoints(macID: UUID, host: String?, presencePort: Int?, attachPort: Int?) {
        guard let idx = macs.firstIndex(where: { $0.macID == macID }) else { return }
        if let host { macs[idx].lastHost = host }
        if let presencePort { macs[idx].presencePort = presencePort }
        if let attachPort { macs[idx].attachPort = attachPort }
        persist()
        onChange?()
    }

    func updateLastSeen(macID: UUID) {
        guard let idx = macs.firstIndex(where: { $0.macID == macID }) else { return }
        macs[idx].lastSeenAt = Date()
        persist()
        onChange?()
    }

    func remove(macID: UUID) {
        macs.removeAll { $0.macID == macID }
        keychain.delete(account: KeychainAccount.secret(macID: macID))
        persist()
        onChange?()
        pairingLogger.log("mac_removed_locally mac_id=\(macID.uuidString, privacy: .public)")
    }

    func removeAll() {
        for mac in macs {
            keychain.delete(account: KeychainAccount.secret(macID: mac.macID))
        }
        macs.removeAll()
        persist()
        onChange?()
        pairingLogger.log("all_macs_removed_locally")
    }

    private func persist() {
        if let data = try? JSONEncoder.pairingMobile.encode(macs) {
            defaults.set(data, forKey: DefaultsKey.pairedMacs)
        }
    }

    private static func loadMacs(defaults: UserDefaults) -> [PairedMac] {
        guard let data = defaults.data(forKey: DefaultsKey.pairedMacs),
              let list = try? JSONDecoder.pairingMobile.decode([PairedMac].self, from: data) else {
            return []
        }
        return list
    }
}

extension JSONEncoder {
    static let pairingMobile: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let pairingMobile: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
