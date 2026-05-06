import Foundation

public enum PairDeviceQRError: Error, Equatable {
    case unsupportedScheme
    case unsupportedPath
    case missingField(String)
    case unsupportedVersion(String)
    case invalidHouseholdPublicKey
    case invalidNonce
    case invalidExpiry
    case expired
    case unsupportedCriticalField(String)
}

public struct PairDeviceQR: Equatable, Sendable {
    public let version: Int
    public let householdPublicKey: Data
    public let householdId: String
    public let nonce: Data
    public let expiresAt: Date
    public let criticalFields: [String]

    public init(
        version: Int,
        householdPublicKey: Data,
        householdId: String,
        nonce: Data,
        expiresAt: Date,
        criticalFields: [String] = []
    ) {
        self.version = version
        self.householdPublicKey = householdPublicKey
        self.householdId = householdId
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.criticalFields = criticalFields
    }

    public init(url: URL, now: Date = Date()) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "soyeht" else {
            throw PairDeviceQRError.unsupportedScheme
        }
        guard components.host == "household", components.path == "/pair-device" else {
            throw PairDeviceQRError.unsupportedPath
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        guard let versionValue = value("v") else { throw PairDeviceQRError.missingField("v") }
        guard versionValue == "1" else { throw PairDeviceQRError.unsupportedVersion(versionValue) }

        let supportedFields: Set<String> = ["v", "hh_pub", "nonce", "ttl", "p_id", "name", "display_name", "crit"]
        let criticalFields = items.flatMap { item -> [String] in
            if item.name == "crit" {
                return item.value?.split(separator: ",").map(String.init) ?? []
            }
            if item.name.hasPrefix("crit_") || item.name.hasPrefix("critical_") {
                return [item.name]
            }
            return []
        }
        for field in criticalFields where !supportedFields.contains(field) {
            throw PairDeviceQRError.unsupportedCriticalField(field)
        }

        guard let publicKeyValue = value("hh_pub") else {
            throw PairDeviceQRError.missingField("hh_pub")
        }
        let householdPublicKey: Data
        do {
            householdPublicKey = try Data(soyehtBase64URL: publicKeyValue)
            try HouseholdIdentifiers.validateCompressedP256PublicKey(householdPublicKey)
        } catch {
            throw PairDeviceQRError.invalidHouseholdPublicKey
        }

        guard let nonceValue = value("nonce") else { throw PairDeviceQRError.missingField("nonce") }
        let nonce: Data
        do {
            nonce = try Data(soyehtBase64URL: nonceValue)
            guard nonce.count == 32 else { throw PairDeviceQRError.invalidNonce }
        } catch {
            throw PairDeviceQRError.invalidNonce
        }

        guard let ttlValue = value("ttl") else { throw PairDeviceQRError.missingField("ttl") }
        guard let ttl = TimeInterval(ttlValue), ttl > 0 else {
            throw PairDeviceQRError.invalidExpiry
        }
        let expiresAt = Date(timeIntervalSince1970: ttl)
        guard expiresAt > now else { throw PairDeviceQRError.expired }

        self.init(
            version: 1,
            householdPublicKey: householdPublicKey,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey),
            nonce: nonce,
            expiresAt: expiresAt,
            criticalFields: criticalFields.sorted()
        )
    }
}
