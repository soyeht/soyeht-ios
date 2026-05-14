import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum HouseholdDevicePairingError: Error, Equatable, Sendable {
    case invalidLink
    case identityKeyUnavailable
    case biometryCanceled
    case requestRejected
    case approvalTimedOut
    case approvalRejected
    case networkUnavailable
    case certInvalid
    case storageFailed
}

public struct HouseholdDevicePairingLink: Equatable, Sendable {
    public let endpoint: URL
    public let householdId: String
    public let householdPublicKey: Data
    public let householdName: String

    public init(
        endpoint: URL,
        householdId: String,
        householdPublicKey: Data,
        householdName: String
    ) {
        self.endpoint = endpoint
        self.householdId = householdId
        self.householdPublicKey = householdPublicKey
        self.householdName = householdName
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "soyeht",
              components.host == "household",
              components.path == "/device-pairing",
              let endpointValue = components.queryItems?.first(where: { $0.name == "endpoint" })?.value,
              let endpoint = URL(string: endpointValue),
              let householdId = components.queryItems?.first(where: { $0.name == "hh_id" })?.value,
              let householdPublicKeyValue = components.queryItems?.first(where: { $0.name == "hh_pub" })?.value,
              let householdPublicKey = try? Data(soyehtBase64URL: householdPublicKeyValue),
              householdPublicKey.count == HouseholdIdentifiers.compressedP256PublicKeyLength else {
            throw HouseholdDevicePairingError.invalidLink
        }
        self.endpoint = endpoint
        self.householdId = householdId
        self.householdPublicKey = householdPublicKey
        self.householdName = components.queryItems?.first(where: { $0.name == "house_name" })?.value ?? "Home"
    }

    public func url() throws -> URL {
        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/device-pairing"
        components.queryItems = [
            URLQueryItem(name: "endpoint", value: endpoint.absoluteString),
            URLQueryItem(name: "hh_id", value: householdId),
            URLQueryItem(name: "hh_pub", value: householdPublicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "house_name", value: householdName),
        ]
        guard let url = components.url else {
            throw HouseholdDevicePairingError.invalidLink
        }
        return url
    }
}

public struct DevicePairingRequestResponse: Decodable, Equatable, Sendable {
    public let version: Int
    public let requestId: String
    public let token: String
    public let expiresAt: UInt64

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case requestId = "request_id"
        case token
        case expiresAt = "expires_at"
    }
}

public struct DevicePairingPollResponse: Decodable, Equatable, Sendable {
    public let version: Int
    public let status: String
    public let householdId: String?
    public let personId: String?
    public let personCertCBOR: String?
    public let deviceCertCBOR: String?
    public let capabilities: [String]?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case status
        case householdId = "hh_id"
        case personId = "p_id"
        case personCertCBOR = "person_cert_cbor"
        case deviceCertCBOR = "device_cert_cbor"
        case capabilities
    }
}

public struct DevicePairingApprovalAck: Decodable, Equatable, Sendable {
    public let version: Int

    enum CodingKeys: String, CodingKey {
        case version = "v"
    }
}

public protocol HouseholdDevicePairingHTTPClient: Sendable {
    func requestPairing(
        endpoint: URL,
        devicePublicKey: Data,
        deviceName: String,
        platform: String
    ) async throws -> DevicePairingRequestResponse

    func pollPairing(
        endpoint: URL,
        requestId: String,
        token: String
    ) async throws -> DevicePairingPollResponse

    func approvePairing(
        endpoint: URL,
        requestId: String,
        deviceCertCBOR: Data,
        authorization: String
    ) async throws -> DevicePairingApprovalAck
}

public struct URLSessionHouseholdDevicePairingHTTPClient: HouseholdDevicePairingHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func requestPairing(
        endpoint: URL,
        devicePublicKey: Data,
        deviceName: String,
        platform: String
    ) async throws -> DevicePairingRequestResponse {
        let body: [String: Any] = [
            "v": 1,
            "d_pub": devicePublicKey.soyehtBase64URLEncodedString(),
            "device_name": deviceName,
            "platform": platform,
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var request = URLRequest(url: Self.url(endpoint: endpoint, path: "/api/v1/household/device-pairing/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HouseholdDevicePairingError.requestRejected
        }
        return try JSONDecoder().decode(DevicePairingRequestResponse.self, from: responseData)
    }

    public func pollPairing(
        endpoint: URL,
        requestId: String,
        token: String
    ) async throws -> DevicePairingPollResponse {
        var components = URLComponents(
            url: Self.url(endpoint: endpoint, path: "/api/v1/household/device-pairing/\(requestId)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else {
            throw HouseholdDevicePairingError.invalidLink
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw HouseholdDevicePairingError.networkUnavailable
        }
        guard http.statusCode == 202 || (200..<300).contains(http.statusCode) else {
            throw HouseholdDevicePairingError.approvalRejected
        }
        return try JSONDecoder().decode(DevicePairingPollResponse.self, from: data)
    }

    public func approvePairing(
        endpoint: URL,
        requestId: String,
        deviceCertCBOR: Data,
        authorization: String
    ) async throws -> DevicePairingApprovalAck {
        let data = try Self.approvalBody(requestId: requestId, deviceCertCBOR: deviceCertCBOR)
        var request = URLRequest(url: Self.url(endpoint: endpoint, path: "/api/v1/household/device-pairing/approve"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HouseholdDevicePairingError.approvalRejected
        }
        return try JSONDecoder().decode(DevicePairingApprovalAck.self, from: responseData)
    }

    public static func approvalPathAndQuery() -> String {
        "/api/v1/household/device-pairing/approve"
    }

    public static func approvalBody(requestId: String, deviceCertCBOR: Data) throws -> Data {
        let body: [String: Any] = [
            "v": 1,
            "request_id": requestId,
            "device_cert_cbor": deviceCertCBOR.soyehtBase64URLEncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func url(endpoint: URL, path: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = basePath.isEmpty ? path : "/\(basePath)\(path)"
        components.percentEncodedQuery = nil
        components.fragment = nil
        return components.url!
    }
}

public struct HouseholdDevicePairingService {
    private let keyProvider: any OwnerIdentityKeyCreating
    private let httpClient: any HouseholdDevicePairingHTTPClient
    private let sessionStore: HouseholdSessionStore
    private let now: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(),
        httpClient: any HouseholdDevicePairingHTTPClient = URLSessionHouseholdDevicePairingHTTPClient(),
        sessionStore: HouseholdSessionStore = HouseholdSessionStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.keyProvider = keyProvider
        self.httpClient = httpClient
        self.sessionStore = sessionStore
        self.now = now
        self.sleeper = sleeper
    }

    public func pair(link: HouseholdDevicePairingLink, deviceName: String = Self.defaultDeviceName()) async throws -> ActiveHouseholdState {
        let deviceIdentity: any OwnerIdentitySigning
        do {
            deviceIdentity = try keyProvider.createOwnerIdentity(displayName: deviceName)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw HouseholdDevicePairingError.biometryCanceled
        } catch {
            throw HouseholdDevicePairingError.identityKeyUnavailable
        }

        let request: DevicePairingRequestResponse
        do {
            request = try await httpClient.requestPairing(
                endpoint: link.endpoint,
                devicePublicKey: deviceIdentity.publicKey,
                deviceName: deviceName,
                platform: Self.platformName()
            )
        } catch let error as HouseholdDevicePairingError {
            throw error
        } catch {
            throw HouseholdDevicePairingError.networkUnavailable
        }

        guard request.version == 1 else {
            throw HouseholdDevicePairingError.requestRejected
        }

        while UInt64(max(0, now().timeIntervalSince1970)) < request.expiresAt {
            try Task.checkCancellation()
            let response: DevicePairingPollResponse
            do {
                response = try await httpClient.pollPairing(
                    endpoint: link.endpoint,
                    requestId: request.requestId,
                    token: request.token
                )
            } catch let error as HouseholdDevicePairingError {
                throw error
            } catch {
                throw HouseholdDevicePairingError.networkUnavailable
            }
            if response.status == "pending" {
                try await sleeper(1)
                continue
            }
            return try persistApprovedPairing(
                response,
                link: link,
                deviceIdentity: deviceIdentity
            )
        }

        throw HouseholdDevicePairingError.approvalTimedOut
    }

    public func approve(
        requestId: String,
        devicePublicKey: Data,
        deviceName: String,
        platform: String,
        household: ActiveHouseholdState,
        ownerIdentity: any OwnerIdentitySigning
    ) async throws {
        let deviceCertCBOR = try DeviceCert.signedCBOR(
            householdId: household.householdId,
            personCert: household.personCert,
            devicePublicKey: devicePublicKey,
            deviceName: deviceName,
            platform: platform,
            issuedAt: now(),
            signer: ownerIdentity
        )
        let bodyData = try URLSessionHouseholdDevicePairingHTTPClient.approvalBody(
            requestId: requestId,
            deviceCertCBOR: deviceCertCBOR
        )
        let authorization = try HouseholdPoPSigner(ownerIdentity: ownerIdentity, now: now).authorization(
            method: "POST",
            pathAndQuery: URLSessionHouseholdDevicePairingHTTPClient.approvalPathAndQuery(),
            body: bodyData
        ).authorizationHeader
        _ = try await httpClient.approvePairing(
            endpoint: household.endpoint,
            requestId: requestId,
            deviceCertCBOR: deviceCertCBOR,
            authorization: authorization
        )
    }

    private func persistApprovedPairing(
        _ response: DevicePairingPollResponse,
        link: HouseholdDevicePairingLink,
        deviceIdentity: any OwnerIdentitySigning
    ) throws -> ActiveHouseholdState {
        guard response.version == 1,
              response.status == "approved",
              response.householdId == link.householdId,
              let personId = response.personId,
              let personCertValue = response.personCertCBOR,
              let deviceCertValue = response.deviceCertCBOR,
              let capabilities = response.capabilities else {
            throw HouseholdDevicePairingError.certInvalid
        }
        let personCertData = try Data(soyehtBase64URL: personCertValue)
        let deviceCertData = try Data(soyehtBase64URL: deviceCertValue)
        let personCert = try PersonCert(cbor: personCertData)
        try personCert.validate(
            householdId: link.householdId,
            householdPublicKey: link.householdPublicKey,
            ownerPersonId: personId,
            ownerPersonPublicKey: personCert.personPublicKey,
            now: now()
        )
        guard Set(capabilities) == Set(personCert.caveats.map(\.operation)) else {
            throw HouseholdDevicePairingError.certInvalid
        }
        let deviceCert = try DeviceCert(cbor: deviceCertData)
        try deviceCert.validate(
            householdId: link.householdId,
            ownerPersonId: personId,
            ownerPersonPublicKey: personCert.personPublicKey,
            now: now()
        )
        guard deviceCert.devicePublicKey == deviceIdentity.publicKey else {
            throw HouseholdDevicePairingError.certInvalid
        }

        let state = ActiveHouseholdState(
            householdId: link.householdId,
            householdName: link.householdName,
            householdPublicKey: link.householdPublicKey,
            endpoint: link.endpoint,
            ownerPersonId: personId,
            ownerPublicKey: personCert.personPublicKey,
            ownerKeyReference: deviceIdentity.keyReference,
            personCert: personCert,
            devicePublicKey: deviceIdentity.publicKey,
            deviceKeyReference: deviceIdentity.keyReference,
            deviceCertCBOR: deviceCertData,
            pairedAt: now(),
            lastSeenAt: now()
        )
        do {
            try sessionStore.save(state)
        } catch {
            throw HouseholdDevicePairingError.storageFailed
        }
        return state
    }

    public static func defaultDeviceName() -> String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Device"
        #endif
    }

    public static func platformName() -> String {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #else
        "ios"
        #endif
    }
}
