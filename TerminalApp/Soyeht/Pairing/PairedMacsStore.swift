import Foundation
import SoyehtCore
import UIKit
import os

private let pairingLogger = Logger(subsystem: "com.soyeht.mobile", category: "pairing")

// MARK: - Mac Display Name (read this if you render a Mac anywhere in the UI)
//
// A `PairedMac` has TWO name fields with distinct roles:
//
//   - `name`  — the hostname the Mac engine sent at pairing time
//               (e.g. "machine-alpha"). Useful for diagnostics, logs, and as a
//               default suggestion when the user has not chosen an alias yet.
//               NEVER render this directly in a SwiftUI view.
//
//   - `alias` — the user-typed display name (e.g. "Alpha Mac"). Set via
//               `PairedMacsStore.setAlias(macID:alias:)` which enforces:
//                 * non-empty + length ≤ `MacAliasRules.maxLength`,
//                 * no forbidden characters (`MacAliasRules.forbiddenChars`),
//                 * uniqueness across all paired Macs (case-insensitive).
//
// The single rule for all UI surfaces: read `mac.displayName`. It returns the
// alias when set, falling back to `name` until the user names the Mac. See
// `docs/mac-display-name.md` for the full contract.
public struct PairedMac: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID { macID }
    public let macID: UUID
    public var name: String
    /// User-typed display name. `nil` means the user has not chosen one yet
    /// — UI MUST read `displayName` (not `alias` and not `name`).
    public var alias: String?
    public var lastHost: String?
    public var presencePort: Int?
    public var attachPort: Int?
    public var engineMachineId: String?
    public let firstPairedAt: Date
    public var lastSeenAt: Date

    /// CANONICAL user-facing label. Prefers `alias` (user-typed) over `name`
    /// (hostname). Every SwiftUI view that shows a Mac MUST read this.
    public var displayName: String {
        if let alias, !alias.trimmingCharacters(in: .whitespaces).isEmpty {
            return alias
        }
        return name
    }

    /// Whether the user still owes us a name for this Mac. Pairing flows
    /// route to `MacAliasView` whenever this is true.
    public var needsAlias: Bool {
        alias?.trimmingCharacters(in: .whitespaces).isEmpty ?? true
    }

    public init(
        macID: UUID,
        name: String,
        alias: String? = nil,
        lastHost: String? = nil,
        presencePort: Int? = nil,
        attachPort: Int? = nil,
        engineMachineId: String? = nil,
        firstPairedAt: Date,
        lastSeenAt: Date
    ) {
        self.macID = macID
        self.name = name
        self.alias = alias
        self.lastHost = lastHost
        self.presencePort = presencePort
        self.attachPort = attachPort
        self.engineMachineId = Self.normalizedEngineMachineId(engineMachineId)
        self.firstPairedAt = firstPairedAt
        self.lastSeenAt = lastSeenAt
    }

    static func normalizedEngineMachineId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case macID
        case name
        case alias
        case lastHost
        case presencePort
        case attachPort
        case engineMachineId
        case firstPairedAt
        case lastSeenAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.macID = try container.decode(UUID.self, forKey: .macID)
        self.name = try container.decode(String.self, forKey: .name)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.lastHost = try container.decodeIfPresent(String.self, forKey: .lastHost)
        self.presencePort = try container.decodeIfPresent(Int.self, forKey: .presencePort)
        self.attachPort = try container.decodeIfPresent(Int.self, forKey: .attachPort)
        self.engineMachineId = Self.normalizedEngineMachineId(
            try container.decodeIfPresent(String.self, forKey: .engineMachineId)
        )
        self.firstPairedAt = try container.decode(Date.self, forKey: .firstPairedAt)
        self.lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
    }
}

// MARK: - Alias validation

/// Rules enforced by `PairedMacsStore.setAlias`. Centralised here so the
/// naming screen, the rename screen, and any tests stay aligned without
/// duplicating literals.
public enum MacAliasRules {
    public static let maxLength = 32
    public static let forbiddenChars = CharacterSet(charactersIn: "/:\\*?\"<>|")
}

public enum MacAliasError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case forbiddenCharacters
}

public enum SetAliasResult: Equatable, Sendable {
    case success
    /// Another Mac already uses this alias (compared case-insensitively).
    case duplicate(conflictingMacID: UUID)
    case invalid(MacAliasError)
    /// The given `macID` is not in the store.
    case unknownMac
}

/// Pure validator — no I/O, no store mutation. Reused by tests, the naming
/// screen's live validation, and `PairedMacsStore.setAlias`.
public enum MacAliasValidator {
    public static func validate(_ raw: String) -> Result<String, MacAliasError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= MacAliasRules.maxLength else { return .failure(.tooLong) }
        guard trimmed.unicodeScalars.allSatisfy({ !MacAliasRules.forbiddenChars.contains($0) }) else {
            return .failure(.forbiddenCharacters)
        }
        return .success(trimmed)
    }
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

    func macIDsWithSecret() -> Set<String> {
        Set(macs.compactMap { mac in
            secret(for: mac.macID) == nil ? nil : mac.macID.uuidString
        })
    }

    func storeSecret(_ secret: Data, for macID: UUID) {
        let base64 = PairingCrypto.base64URLEncode(secret)
        keychain.saveString(base64, account: KeychainAccount.secret(macID: macID))
        pairingLogger.log("pair_secret_stored mac_id=\(macID.uuidString, privacy: .public)")
    }

    // MARK: - Mac registry

    func upsertMac(
        macID: UUID,
        name: String,
        host: String?,
        presencePort: Int? = nil,
        attachPort: Int? = nil,
        engineMachineId: String? = nil
    ) {
        let now = Date()
        let normalizedEngineMachineId = PairedMac.normalizedEngineMachineId(engineMachineId)
        if let idx = macs.firstIndex(where: { $0.macID == macID }) {
            macs[idx].name = name
            macs[idx].lastSeenAt = now
            if let host { macs[idx].lastHost = host }
            if let presencePort { macs[idx].presencePort = presencePort }
            if let attachPort { macs[idx].attachPort = attachPort }
            if let normalizedEngineMachineId {
                macs[idx].engineMachineId = normalizedEngineMachineId
            }
        } else {
            macs.append(PairedMac(
                macID: macID,
                name: name,
                lastHost: host,
                presencePort: presencePort,
                attachPort: attachPort,
                engineMachineId: normalizedEngineMachineId,
                firstPairedAt: now,
                lastSeenAt: now
            ))
        }
        persist()
        onChange?()
    }

    @discardableResult
    func setEngineMachineId(macID: UUID, engineMachineId: String?) -> Bool {
        guard let normalized = PairedMac.normalizedEngineMachineId(engineMachineId),
              let idx = macs.firstIndex(where: { $0.macID == macID }) else {
            return false
        }
        guard macs[idx].engineMachineId != normalized else { return false }
        macs[idx].engineMachineId = normalized
        persist()
        onChange?()
        return true
    }

    func updateDisplayName(macID: UUID, name: String) {
        guard let idx = macs.firstIndex(where: { $0.macID == macID }) else { return }
        guard macs[idx].name != name else { return }
        macs[idx].name = name
        persist()
        onChange?()
    }

    // MARK: - Mac alias (user-typed display name)
    //
    // This is the single mutator for `PairedMac.alias`. The validation here
    // is the contract that `MacAliasView` and `PairedMacsListView` (rename)
    // depend on. Do not bypass this method by writing `alias` directly —
    // tests will catch it, and you will reintroduce duplicates.

    /// Sets the user-typed alias on a Mac, after running it through
    /// `MacAliasValidator` and a uniqueness check across other paired
    /// Macs (case-insensitive). On `.success` the change is persisted
    /// and `onChange` fires.
    @discardableResult
    func setAlias(macID: UUID, alias rawAlias: String) -> SetAliasResult {
        let trimmed: String
        switch MacAliasValidator.validate(rawAlias) {
        case .failure(let err): return .invalid(err)
        case .success(let value): trimmed = value
        }

        if let conflict = macs.first(where: {
            $0.macID != macID
                && ($0.alias?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame)
        }) {
            return .duplicate(conflictingMacID: conflict.macID)
        }

        guard let idx = macs.firstIndex(where: { $0.macID == macID }) else {
            return .unknownMac
        }

        guard macs[idx].alias != trimmed else { return .success }
        macs[idx].alias = trimmed
        persist()
        onChange?()
        return .success
    }

    @discardableResult
    func setDefaultAliasIfNeeded(macID: UUID, suggestedAlias rawAlias: String) -> SetAliasResult {
        guard let mac = macs.first(where: { $0.macID == macID }) else {
            return .unknownMac
        }
        guard mac.needsAlias else { return .success }

        let base = Self.defaultAliasBase(from: rawAlias)
        for index in 0..<100 {
            let candidate = Self.defaultAliasCandidate(base: base, duplicateIndex: index)
            switch setAlias(macID: macID, alias: candidate) {
            case .success:
                return .success
            case .duplicate:
                continue
            case .invalid(let error):
                return .invalid(error)
            case .unknownMac:
                return .unknownMac
            }
        }
        return .duplicate(conflictingMacID: macID)
    }

    private static func defaultAliasBase(from rawAlias: String) -> String {
        let cleanedScalars = rawAlias.unicodeScalars.filter { scalar in
            !MacAliasRules.forbiddenChars.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Mac" : cleaned
        return String(base.prefix(MacAliasRules.maxLength))
    }

    private static func defaultAliasCandidate(base: String, duplicateIndex: Int) -> String {
        guard duplicateIndex > 0 else { return base }
        let suffix = " \(duplicateIndex + 1)"
        let maxBaseLength = max(1, MacAliasRules.maxLength - suffix.count)
        return String(base.prefix(maxBaseLength)) + suffix
    }

    /// Returns the `PairedMac` that backs an engine-kind `PairedServer`,
    /// by matching the server's host against `lastHost`. Used by views like
    /// `ServerListView` and `ClawSetupView` to surface the alias instead
    /// of the hostname when the Mac has been named. Returns `nil` for
    /// non-engine kinds or when no match is found.
    func paired(forServer server: PairedServer) -> PairedMac? {
        guard server.kind == .engine else { return nil }
        return macs.first(where: { $0.lastHost == server.host })
    }

    /// Single helper for views that show a `PairedServer` and want the
    /// alias-aware label. Engine-kind servers that map to a known Mac get
    /// `mac.displayName`; everything else falls through to
    /// `server.displayName`. UI surfaces should call this instead of
    /// rolling their own lookup.
    func displayName(forServer server: PairedServer) -> String {
        if let mac = paired(forServer: server) {
            return mac.displayName
        }
        return server.displayName
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
