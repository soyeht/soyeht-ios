import Foundation

public struct PairDeviceConfirmResponse: Decodable, Equatable, Sendable {
    public let v: Int
    public let householdId: String
    public let personId: String
    public let personCertCBOR: String
    public let capabilities: [String]
    public let deviceCert: String?

    enum CodingKeys: String, CodingKey {
        case v
        case householdId = "hh_id"
        case personId = "p_id"
        case personCertCBOR = "person_cert_cbor"
        case capabilities
        case deviceCert = "device_cert"
    }

    public init(
        v: Int,
        householdId: String,
        personId: String,
        personCertCBOR: String,
        capabilities: [String],
        deviceCert: String? = nil
    ) {
        self.v = v
        self.householdId = householdId
        self.personId = personId
        self.personCertCBOR = personCertCBOR
        self.capabilities = capabilities
        self.deviceCert = deviceCert
    }
}

public protocol HouseholdPairingHTTPClient: Sendable {
    func confirmPairing(
        endpoint: URL,
        body: PairDeviceConfirmRequest
    ) async throws -> PairDeviceConfirmResponse
}

public struct URLSessionHouseholdPairingHTTPClient: HouseholdPairingHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func confirmPairing(
        endpoint: URL,
        body: PairDeviceConfirmRequest
    ) async throws -> PairDeviceConfirmResponse {
        let url = endpoint.appending(path: "/api/v1/household/pair-device/confirm")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HouseholdPairingError.pairingRejected
        }
        return try JSONDecoder().decode(PairDeviceConfirmResponse.self, from: data)
    }
}

public struct HouseholdPairingService {
    private static let maxPersonCertCBORBase64URLBytes = 90_000

    private let browser: any HouseholdBonjourBrowsing
    private let keyProvider: any OwnerIdentityKeyCreating
    private let httpClient: any HouseholdPairingHTTPClient
    private let sessionStore: HouseholdSessionStore
    private let now: @Sendable () -> Date

    public init(
        browser: any HouseholdBonjourBrowsing = HouseholdBonjourBrowser(),
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(),
        httpClient: any HouseholdPairingHTTPClient = URLSessionHouseholdPairingHTTPClient(),
        sessionStore: HouseholdSessionStore = HouseholdSessionStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.browser = browser
        self.keyProvider = keyProvider
        self.httpClient = httpClient
        self.sessionStore = sessionStore
        self.now = now
    }

    public func pair(url: URL, displayName: String) async throws -> ActiveHouseholdState {
        let qr: PairDeviceQR
        do {
            qr = try PairDeviceQR(url: url, now: now())
        } catch PairDeviceQRError.expired {
            throw HouseholdPairingError.expiredQR
        } catch {
            throw HouseholdPairingError.invalidQR
        }

        let candidate: HouseholdDiscoveryCandidate
        do {
            candidate = try await browser.firstMatchingCandidate(for: qr, timeout: 10)
        } catch let error as HouseholdPairingError {
            throw error
        } catch {
            throw HouseholdPairingError.noMatchingHousehold
        }

        let ownerIdentity: any OwnerIdentitySigning
        do {
            ownerIdentity = try keyProvider.createOwnerIdentity(displayName: displayName)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw HouseholdPairingError.biometryCanceled
        } catch {
            throw HouseholdPairingError.identityKeyUnavailable
        }

        let request: PairDeviceConfirmRequest
        do {
            request = try PairingProof.confirmRequest(qr: qr, ownerIdentity: ownerIdentity, displayName: displayName)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw HouseholdPairingError.biometryCanceled
        } catch {
            throw HouseholdPairingError.identityKeyUnavailable
        }

        let response: PairDeviceConfirmResponse
        do {
            response = try await httpClient.confirmPairing(endpoint: candidate.endpoint, body: request)
        } catch let error as HouseholdPairingError {
            throw error
        } catch {
            throw HouseholdPairingError.networkUnavailable
        }

        guard response.v == 1 else { throw HouseholdPairingError.certInvalid }
        guard response.deviceCert == nil else { throw HouseholdPairingError.certInvalid }
        guard response.householdId == qr.householdId, response.personId == ownerIdentity.personId else {
            throw HouseholdPairingError.certInvalid
        }
        guard response.personCertCBOR.utf8.count <= Self.maxPersonCertCBORBase64URLBytes else {
            throw HouseholdPairingError.certInvalid
        }

        let certData: Data
        do {
            certData = try Data(soyehtBase64URL: response.personCertCBOR)
            let cert = try PersonCert(cbor: certData)
            guard Set(response.capabilities) == Set(cert.caveats.map(\.operation)) else {
                throw HouseholdPairingError.certInvalid
            }
            try cert.validate(
                householdId: qr.householdId,
                householdPublicKey: qr.householdPublicKey,
                ownerPersonId: ownerIdentity.personId,
                ownerPersonPublicKey: ownerIdentity.publicKey,
                now: now()
            )
            let state = ActiveHouseholdState(
                householdId: qr.householdId,
                householdName: candidate.householdName,
                householdPublicKey: qr.householdPublicKey,
                endpoint: candidate.endpoint,
                ownerPersonId: ownerIdentity.personId,
                ownerPublicKey: ownerIdentity.publicKey,
                ownerKeyReference: ownerIdentity.keyReference,
                personCert: cert,
                pairedAt: now(),
                lastSeenAt: now()
            )
            try sessionStore.save(state)
            return state
        } catch HouseholdSessionError.storageFailed {
            throw HouseholdPairingError.storageFailed
        } catch let error as HouseholdPairingError {
            throw error
        } catch {
            throw HouseholdPairingError.certInvalid
        }
    }
}
