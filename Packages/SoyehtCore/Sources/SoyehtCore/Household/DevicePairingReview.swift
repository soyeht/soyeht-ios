import CryptoKit
import Foundation

/// The words bind approval to this request and device key, not its display name.
public struct DevicePairingReview: Equatable, Sendable, Identifiable {
    public let id: String
    public let devicePublicKey: Data
    public let deviceName: String
    public let platform: String
    public let expiresAt: Date
    public let words: [String]

    public var diagnostic: String {
        let digest = SHA256.hash(data: Data(words.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "pairing_review_digest=\(digest)"
    }

    public init(requestID: String, devicePublicKey: Data, deviceName: String,
                platform: String, expiresAt: UInt64, householdPublicKey: Data) throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 128 else {
            throw HouseholdDevicePairingError.requestRejected
        }
        try HouseholdIdentifiers.validateCompressedP256PublicKey(devicePublicKey)
        let challenge = Data("soyeht.device-pairing-review.v1\0".utf8)
            + Data(requestID.utf8) + Data([0]) + devicePublicKey
        let nonce = Data(SHA256.hash(data: challenge))
        self.words = try OperatorFingerprint.derive(machinePublicKey: householdPublicKey,
            pairingNonce: nonce, wordlist: BIP39Wordlist()).words
        self.id = requestID
        self.devicePublicKey = devicePublicKey
        self.deviceName = deviceName
        self.platform = platform
        self.expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }
}

public struct DevicePairingRequestSummary: Decodable, Sendable {
    public let requestID: String
    public let devicePublicKey: String
    public let deviceName: String
    public let platform: String
    public let expiresAt: UInt64
    public let status: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", devicePublicKey = "d_pub", deviceName = "device_name"
        case platform, expiresAt = "expires_at", status
    }

    public func review(householdPublicKey: Data) throws -> DevicePairingReview {
        try DevicePairingReview(requestID: requestID,
            devicePublicKey: Data(soyehtBase64URL: devicePublicKey), deviceName: deviceName,
            platform: platform, expiresAt: expiresAt, householdPublicKey: householdPublicKey)
    }
}

public struct DevicePairingRequestsResponse: Decodable, Sendable {
    public let version: Int
    public let requests: [DevicePairingRequestSummary]
    enum CodingKeys: String, CodingKey { case version = "v", requests }
}
