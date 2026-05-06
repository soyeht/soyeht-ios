import Foundation
import Security

public enum HouseholdSessionError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case storageFailed
    case missingSession
}

public struct ActiveHouseholdState: Codable, Equatable, Sendable {
    public let householdId: String
    public let householdName: String
    public let householdPublicKey: Data
    public let endpoint: URL
    public let ownerPersonId: String
    public let ownerPublicKey: Data
    public let ownerKeyReference: String
    public let personCert: PersonCert
    public let pairedAt: Date
    public let lastSeenAt: Date?

    public init(
        householdId: String,
        householdName: String,
        householdPublicKey: Data,
        endpoint: URL,
        ownerPersonId: String,
        ownerPublicKey: Data,
        ownerKeyReference: String,
        personCert: PersonCert,
        pairedAt: Date,
        lastSeenAt: Date?
    ) {
        self.householdId = householdId
        self.householdName = householdName
        self.householdPublicKey = householdPublicKey
        self.endpoint = endpoint
        self.ownerPersonId = ownerPersonId
        self.ownerPublicKey = ownerPublicKey
        self.ownerKeyReference = ownerKeyReference
        self.personCert = personCert
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

public protocol HouseholdSecureStoring: Sendable {
    func save(_ data: Data, account: String) -> Bool
    func load(account: String) -> Data?
    func delete(account: String)
}

extension KeychainHelper: HouseholdSecureStoring {}

public struct HouseholdSessionStore {
    public static let activeSessionAccount = "household.active.session"

    private let storage: any HouseholdSecureStoring
    private let account: String

    public init(
        storage: any HouseholdSecureStoring = KeychainHelper(
            service: "com.soyeht.household",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ),
        account: String = Self.activeSessionAccount
    ) {
        self.storage = storage
        self.account = account
    }

    public func save(_ state: ActiveHouseholdState) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            throw HouseholdSessionError.encodingFailed
        }
        guard storage.save(data, account: account) else {
            throw HouseholdSessionError.storageFailed
        }
    }

    public func load() throws -> ActiveHouseholdState? {
        guard let data = storage.load(account: account) else { return nil }
        do {
            return try JSONDecoder().decode(ActiveHouseholdState.self, from: data)
        } catch {
            throw HouseholdSessionError.decodingFailed
        }
    }

    public func clear() {
        storage.delete(account: account)
    }
}
