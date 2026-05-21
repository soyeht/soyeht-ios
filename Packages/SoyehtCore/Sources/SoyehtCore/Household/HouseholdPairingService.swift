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
        NSLog("HouseholdPairingService POST url=%@", url.absoluteString)
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
        if let endpoint = Self.directEndpoint(for: qr) {
            // Founder embedded a Tailnet host fallback in the QR (engine's
            // bonjour publisher is known broken cross-platform — Linux
            // mdns-sd does not emit announce records visible to macOS/iOS
            // NWBrowser). Skip Bonjour browse entirely. The household
            // identity is still verified by `PairingProof.confirmRequest`
            // through `qr.householdPublicKey` so this fallback path
            // inherits the same trust model as Bonjour discovery.
            candidate = HouseholdDiscoveryCandidate(
                endpoint: endpoint,
                householdId: qr.householdId,
                householdName: "",
                machineId: nil,
                pairingState: "device",
                shortNonce: ""
            )
        } else {
            do {
                candidate = try await browser.firstMatchingCandidate(for: qr, timeout: 10)
            } catch let error as HouseholdPairingError {
                throw error
            } catch {
                throw HouseholdPairingError.noMatchingHousehold
            }
        }

        let ownerIdentity: any OwnerIdentitySigning
        do {
            ownerIdentity = try keyProvider.createOwnerIdentity(displayName: displayName)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw HouseholdPairingError.biometryCanceled
        } catch let inner {
            // Forward the underlying OwnerIdentityKeyError message via
            // NSLog so a generic `identityKeyUnavailable` surfaced to the
            // user still leaves a diagnosis trail in Console / xcrun
            // devicectl logs. The error is otherwise opaque to callers
            // that catch the rolled-up `HouseholdPairingError`.
            NSLog("HouseholdPairingService.createOwnerIdentity failed: %@", String(describing: inner))
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

        guard response.v == 1 else {
            NSLog("HouseholdPairingService certInvalid guard=v expected=1 got=%d", response.v)
            throw HouseholdPairingError.certInvalid
        }
        guard response.deviceCert == nil else {
            NSLog("HouseholdPairingService certInvalid guard=deviceCert.nil — server returned a device cert on the owner-pair path")
            throw HouseholdPairingError.certInvalid
        }
        guard response.householdId == qr.householdId, response.personId == ownerIdentity.personId else {
            NSLog("HouseholdPairingService certInvalid guard=ids responseHH=%@ qrHH=%@ responsePID=%@ ownerPID=%@",
                  response.householdId, qr.householdId, response.personId, ownerIdentity.personId)
            throw HouseholdPairingError.certInvalid
        }
        guard response.personCertCBOR.utf8.count <= Self.maxPersonCertCBORBase64URLBytes else {
            NSLog("HouseholdPairingService certInvalid guard=cborSize bytes=%d cap=%d", response.personCertCBOR.utf8.count, Self.maxPersonCertCBORBase64URLBytes)
            throw HouseholdPairingError.certInvalid
        }

        let certData: Data
        do {
            certData = try Data(soyehtBase64URL: response.personCertCBOR)
            let cert = try PersonCert(cbor: certData)
            guard Set(response.capabilities) == Set(cert.caveats.map(\.operation)) else {
                NSLog("HouseholdPairingService certInvalid guard=capabilities response=%@ certOps=%@",
                      String(describing: Set(response.capabilities)),
                      String(describing: Set(cert.caveats.map(\.operation))))
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
            NSLog("HouseholdPairingService certInvalid catch-all inner=%@", String(describing: error))
            throw HouseholdPairingError.certInvalid
        }
    }

    /// Constructs an HTTP endpoint URL from a QR's `host` fallback field if
    /// present (`<addr>:<port>` syntax). Returns nil when the QR did not
    /// carry an explicit host — callers must then fall back to Bonjour
    /// discovery. The fallback is plain HTTP because the engine only
    /// listens on cleartext within Tailscale's encrypted overlay and on
    /// loopback. ATS allows arbitrary cleartext loads for the same reason
    /// (see Soyeht/Info.plist).
    static func directEndpoint(for qr: PairDeviceQR) -> URL? {
        guard let host = qr.hostFallback, !host.isEmpty else { return nil }
        return URL(string: "http://\(host)")
    }
}
