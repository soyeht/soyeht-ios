import CryptoKit
import Foundation
import XCTest
@testable import SoyehtCore

/// These tests use live handlers compiled from the other checkout. The only
/// substituted boundary is where a logical LAN/tailnet address is transported
/// to the isolated loopback host; request and response codecs remain real.
final class PairingContractTests: XCTestCase {
    private var output: URL!
    private var endpoints: [String: String]!
    private var completed = Set<String>()

    override func setUpWithError() throws {
        output = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["SOYEHT_PAIRING_CONTRACT_DIR"]))
        endpoints = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: output.appendingPathComponent("bridge.json")))
    }

    private func base(_ key: String) throws -> URL {
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(endpoints[key])))
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertFalse([8091, 8101, 8892].contains(url.port ?? 0))
        return url
    }

    func testLivePairingContract() async throws {
        let founder = try base("founder")
        let ready = try base("ready")
        let token = try SetupInvitationToken(bytes: Data(0..<32))
        let invitation = SetupInvitationPayload(token: token, ownerDisplayName: "Contract Owner",
            expiresAt: UInt64(Date().timeIntervalSince1970 + 240), iphoneApnsToken: nil,
            installation: .init(.release))
        let directResponse = SetupInvitationDirectEndpoint.respond(method: "GET", path: "/setup-invitation",
            body: Data(), invitation: invitation, isPublishing: true)
        XCTAssertEqual(directResponse.status, 200)
        let direct = directResponse.body
        XCTAssertEqual(try SetupInvitationPayload.decodeDirectEndpointData(direct).token, token)
        let verification = SetupInvitationDirectEndpoint.respond(method: "POST", path: "/setup/verify",
            body: Data(), invitation: invitation, isPublishing: true)
        XCTAssertEqual(verification.status, 200)
        try verification.body.write(to: output.appendingPathComponent("phone-verify.cbor"), options: .atomic)
        completed.insert("invitation.get")

        let initial = try await BootstrapStatusClient(baseURL: founder).fetch()
        XCTAssertEqual(initial.state, .uninitialized)
        completed.insert("bootstrap.status")
        let evidence = output!
        let fault = ProcessInfo.processInfo.environment["SOYEHT_PAIRING_CONTRACT_FAULT"]
        let visibility = BootstrapPairDeviceWindowClient(baseURL: founder, transport: { request in
            var request = request
            if fault == "renamed-route" { request.url = request.url!.appendingPathComponent("renamed") }
            var (data, response) = try await URLSession.shared.data(for: request)
            if fault == "renamed-route" {
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
                try Data("renamed-route:404".utf8).write(to: evidence.appendingPathComponent("fault-activated"))
            }
            if fault == "renamed-expiry" {
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                guard case .map(var fields) = try BootstrapWire.decodeCanonical(data),
                      let expiry = fields.removeValue(forKey: "expires_at_unix") else {
                    throw ContractFailure.missingMutationTarget
                }
                fields["expires_at"] = expiry
                data = HouseholdCBOR.encode(.map(fields))
                try Data("renamed-expiry:200".utf8).write(to: evidence.appendingPathComponent("fault-activated"))
            }
            return (data, response)
        })
        let open = try await visibility.open()
        XCTAssertGreaterThan(try XCTUnwrap(open.expiresAt), UInt64(Date().timeIntervalSince1970))
        completed.insert("visibility.open")
        let closed = try await visibility.close()
        XCTAssertNil(closed.expiresAt)
        completed.insert("visibility.close")
        let offer = try await BootstrapPairingAddressesClient(baseURL: founder, installation: .init(.release)).fetch()
        XCTAssertFalse(offer.offer.candidates.isEmpty)
        completed.insert("pairing.addresses")

        let accepted = try await SetupInvitationClaimClient(baseURL: founder).claim(token: token,
            ownerDisplayName: nil, iphoneApnsToken: nil,
            iphoneEndpoint: URL(string: "http://192.168.1.10:9999"), iphoneAddresses: [], expiresAt: nil,
            installation: .init(.release))
        XCTAssertGreaterThan(accepted, 0)
        completed.formUnion(["invitation.verify", "bootstrap.claim"])
        let initialized = try await BootstrapInitializeClient(baseURL: founder).initialize(name: "Contract Home", claimToken: token)
        XCTAssertFalse(initialized.hhId.isEmpty)
        completed.insert("bootstrap.initialize")
        let uri = try await BootstrapPairDeviceURIClient(baseURL: founder, installation: .init(.release)).fetch()
        let qr = try PairDeviceQR(url: XCTUnwrap(URL(string: uri.pairDeviceURI)))
        XCTAssertEqual(qr.householdId, initialized.hhId)
        completed.insert("pairing.uri")

        let notice = SetupInvitationDirectClaim(token: token,
            macEngineURL: URL(string: "http://100.64.0.10:8091")!, installation: .init(.release),
            event: .bootstrapClaimAccepted, addressOffer: offer.offer)
        let notified = SetupInvitationDirectEndpoint.respond(method: "POST", path: "/setup-invitation/claimed",
            body: try notice.encodedData(), invitation: invitation, isPublishing: true)
        XCTAssertEqual(notified.status, 204)
        XCTAssertEqual(notified.notification, notice)
        let wrongProfile = SetupInvitationDirectClaim(token: token, macEngineURL: notice.macEngineURL,
            installation: .init(.dev), event: .bootstrapClaimAccepted, addressOffer: offer.offer)
        let rejected = SetupInvitationDirectEndpoint.respond(method: "POST", path: "/setup-invitation/claimed",
            body: try wrongProfile.encodedData(), invitation: invitation, isPublishing: true)
        XCTAssertEqual(rejected.status, 400)
        XCTAssertNil(rejected.notification)
        completed.insert("invitation.notify")

        let codeWords = try PairingCodePresentation.words(pairingURI: uri.pairDeviceURI)
        let byCode = try await BootstrapWire.send(method: "POST",
            url: founder.appendingPathComponent("bootstrap/pair-device-uri/by-code"),
            body: HouseholdCBOR.encode(.map(["v": .unsigned(1), "words": .array(codeWords.map { .text($0) })])),
            authorization: nil, perform: { try await URLSession.shared.data(for: $0) })
        XCTAssertEqual(try PairDeviceQR(url: XCTUnwrap(URL(string: BootstrapPairDeviceURIClient.decode(byCode).pairDeviceURI))).householdId, qr.householdId)
        completed.insert("pairing.uri_by_code")

        let reissued = try await BootstrapWire.send(method: "POST",
            url: try base("reissue").appendingPathComponent("bootstrap/pair-device/reissue"), body: nil,
            authorization: nil, perform: { try await URLSession.shared.data(for: $0) })
        guard case .map(let reissueMap) = try BootstrapWire.decodeCanonical(reissued),
              case .text(let reissueURI) = reissueMap["pair_qr_uri"],
              case .unsigned(let expires) = reissueMap["expires_at_unix"] else {
            return XCTFail("Invalid reissue response")
        }
        XCTAssertGreaterThan(expires, UInt64(Date().timeIntervalSince1970))
        _ = try PairDeviceQR(url: XCTUnwrap(URL(string: reissueURI)))
        completed.insert("pairing.reissue")

        let firstOwnerStorage = ContractStorage()
        let firstOwnerStore = HouseholdSessionStore(storage: firstOwnerStorage)
        let firstOwner = try await HouseholdPairingService(keyProvider: ContractKeys(),
            httpClient: URLSessionHouseholdPairingHTTPClient(transport: { request in
                var forwarded = request
                forwarded.url = founder.appendingPathComponent(request.url!.path)
                return try await PlainHTTPTransaction(request: forwarded).perform()
            }),
            sessionStore: firstOwnerStore, rosterStorage: firstOwnerStorage).pair(
                url: XCTUnwrap(URL(string: uri.pairDeviceURI)), displayName: "Contract First Owner",
                reachedEndpoint: URL(string: "http://192.168.1.20:8091"),
                phoneNetwork: .init(hasTailnetAddress: true), installation: .init(.release))
        XCTAssertEqual(firstOwner.householdId, qr.householdId)
        XCTAssertEqual(try XCTUnwrap(firstOwnerStore.load()).endpoint.host, "100.64.0.10")
        completed.insert("pairing.first_owner")

        let routing = try routedSession(target: ready)
        defer { routing.invalidateAndCancel() }
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let ownerSigner = try InMemoryOwnerIdentityKey(publicKey: ownerKey.publicKey.compressedRepresentation) {
            try ownerKey.signature(for: $0).rawRepresentation
        }
        let person = try PersonCert(cbor: Data(contentsOf: output.appendingPathComponent("owner-cert.cbor")))
        let houseKey = try Data(contentsOf: output.appendingPathComponent("household-public-key.bin"))
        let ownerSession = ActiveHouseholdState(householdId: person.householdId, householdName: "Contract Home",
            householdPublicKey: houseKey, endpoint: ready, ownerPersonId: person.personId,
            ownerPublicKey: person.personPublicKey, ownerKeyReference: ownerSigner.keyReference,
            personCert: person, pairedAt: Date(), lastSeenAt: nil)
        let readyOffer = try await BootstrapPairingAddressesClient(baseURL: ready, installation: .init(.release)).fetch().offer
        let client = URLSessionHouseholdDevicePairingHTTPClient(session: routing)
        for hasTailnet: Bool? in [true, false, nil] {
            let storage = ContractStorage(downgradeEvidence: fault == "persisted-lan" ? evidence : nil)
            let sessionStore = HouseholdSessionStore(storage: storage)
            let link = HouseholdDevicePairingLink(endpoint: URL(string: "http://192.168.1.20:8091")!,
                householdId: person.householdId, householdPublicKey: houseKey, householdName: "Contract Home",
                pairingNonce: Data(repeating: 2, count: 32), addressOffer: readyOffer)
            let paired = try await HouseholdDevicePairingService(keyProvider: ContractKeys(), httpClient: client,
                sessionStore: sessionStore).pair(link: link, reachedEndpoint: link.endpoint,
                    phoneNetwork: PhoneNetworkEvidence(hasTailnetAddress: hasTailnet), installation: .init(.release),
                    onPending: { review in
                        do {
                            let requests = try await client.listPairingRequests(endpoint: ready, ownerIdentity: ownerSigner)
                            let pending = try XCTUnwrap(requests.first { $0.requestID == review.id })
                            XCTAssertEqual(try pending.review(householdPublicKey: houseKey).words, review.words)
                            try await HouseholdDevicePairingService(httpClient: client).approve(requestId: review.id,
                                devicePublicKey: review.devicePublicKey, deviceName: review.deviceName,
                                platform: review.platform, household: ownerSession, ownerIdentity: ownerSigner)
                        } catch { XCTFail("Owner approval failed: \(error)") }
                    })
            let persisted = try XCTUnwrap(sessionStore.load())
            XCTAssertEqual(persisted.endpoint, paired.endpoint)
            XCTAssertEqual(persisted.endpoint.host, hasTailnet == false ? "192.168.1.20" : "100.64.0.10")
        }
        completed.formUnion(["pairing.request", "pairing.requests", "pairing.approve", "pairing.poll"])
        let joiner = try base("joiner")
        _ = try await SetupInvitationClaimClient(baseURL: joiner).claim(token: token,
            ownerDisplayName: nil, iphoneApnsToken: nil,
            iphoneEndpoint: URL(string: "http://192.168.1.10:9999"), iphoneAddresses: [], expiresAt: nil,
            installation: .init(.release))
        let prepared = try await BootstrapAcceptHouseholdClient(baseURL: joiner).acceptHousehold(
            householdId: person.householdId, householdPublicKey: houseKey,
            householdName: "Contract Home", invitationToken: token)
        XCTAssertTrue(prepared.challengeSigRequired)
        completed.insert("bootstrap.accept_household")
        let signed = try await HouseholdSignMachineCertClient(baseURL: ready,
            popSigner: .init(ownerIdentity: ownerSigner)).signMachineCert(subject: .init(
                machineId: prepared.machineId, machinePublicKey: prepared.machinePublicKey,
                hostname: "contract-joiner", platform: .macos), challenge: prepared.joinChallenge)
        let joined = try await BootstrapAcceptHouseholdConfirmClient(baseURL: joiner).confirm(
            machineId: prepared.machineId, machineCert: signed.machineCert, challengeSig: signed.challengeSignature)
        XCTAssertEqual(joined.householdId, person.householdId)
        XCTAssertEqual(joined.bootstrapState, "ready")
        completed.insert("bootstrap.accept_household_confirm")

        try JSONEncoder().encode(completed.sorted()).write(to: output.appendingPathComponent("swift-routes.json"), options: .atomic)
    }

    private func routedSession(target: URL) throws -> URLSession {
        ContractURLProtocol.target = target
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private enum ContractFailure: Error { case missingMutationTarget }

private struct ContractKeys: OwnerIdentityKeyCreating {
    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        let key = P256.Signing.PrivateKey()
        return try InMemoryOwnerIdentityKey(publicKey: key.publicKey.compressedRepresentation) {
            try key.signature(for: $0).rawRepresentation
        }
    }
    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        throw OwnerIdentityKeyError.keyNotFound
    }
}

private final class ContractStorage: HouseholdSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private let downgradeEvidence: URL?
    init(downgradeEvidence: URL? = nil) { self.downgradeEvidence = downgradeEvidence }
    func save(_ data: Data, account: String) -> Bool {
        var stored = data
        if let downgradeEvidence, account == HouseholdSessionStore.activeSessionAccount,
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           object["endpoint"] as? String == "http://100.64.0.10:8091" {
            object["endpoint"] = "http://192.168.1.20:8091"
            do {
                stored = try JSONSerialization.data(withJSONObject: object)
                try Data("persisted-lan:after-confirm".utf8).write(to: downgradeEvidence.appendingPathComponent("fault-activated"))
            } catch { return false }
        }
        lock.withLock { items[account] = stored }
        return true
    }
    func load(account: String) -> Data? { lock.withLock { items[account] } }
    func delete(account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
}

private final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var target: URL!
    private var forwardingTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        let original = request.url!
        var parts = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        parts.host = Self.target.host
        parts.port = Self.target.port
        parts.scheme = "http"
        forwarded.url = parts.url
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            forwarded.httpBody = data
        }
        forwardingTask = Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: forwarded)
                let http = response as! HTTPURLResponse
                let restored = HTTPURLResponse(url: original, statusCode: http.statusCode,
                    httpVersion: "HTTP/1.1", headerFields: http.allHeaderFields as? [String: String])!
                client?.urlProtocol(self, didReceive: restored, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { forwardingTask?.cancel() }
}
