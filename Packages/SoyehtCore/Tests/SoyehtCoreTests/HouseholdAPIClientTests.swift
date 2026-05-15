import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

private final class HouseholdAPIClientTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var responseData = Data("{\"ok\":true}".utf8)
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 1024)
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            stream.close()
            captured.httpBody = data
        }
        Self.capturedRequest = captured
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        capturedRequest = nil
        responseData = Data("{\"ok\":true}".utf8)
        statusCode = 200
    }
}

private struct HouseholdAPIClientOwnerKeyProvider: OwnerIdentityKeyCreating {
    let key: P256.Signing.PrivateKey

    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        try loadOwnerIdentity(keyReference: "owner-key", publicKey: key.publicKey.compressedRepresentation)
    }

    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        try InMemoryOwnerIdentityKey(publicKey: publicKey, keyReference: keyReference) { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }
}

@Suite("HouseholdAPIClient", .serialized)
struct HouseholdAPIClientTests {
    @Test func householdRequestUsesPoPAuthorizationWithoutBearer() async throws {
        HouseholdAPIClientTestURLProtocol.reset()
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let storage = InMemoryHouseholdStorage()
        let householdStore = HouseholdSessionStore(storage: storage, account: "active")
        let state = try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey)
        try householdStore.save(state)
        let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

        _ = try await client.householdRequest(
            path: "/api/v1/household/members",
            queryItems: [URLQueryItem(name: "limit", value: "10")],
            requiredOperation: "claws.list"
        )

        let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("Soyeht-PoP v1:\(state.ownerPersonId):1714972800:"))
        #expect(!authorization.contains("Bearer"))
        #expect(request.url?.path == "/api/v1/household/members")
        #expect(request.url?.query == "limit=10")
    }

    @Test func invalidLocalCertBlocksHouseholdRequestBeforeNetwork() async throws {
        HouseholdAPIClientTestURLProtocol.reset()
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let wrongHouseholdKey = P256.Signing.PrivateKey()
        let storage = InMemoryHouseholdStorage()
        let householdStore = HouseholdSessionStore(storage: storage, account: "active")
        let state = try makeActiveHouseholdState(
            householdKey: householdKey,
            ownerKey: ownerKey,
            householdPublicKeyOverride: wrongHouseholdKey.publicKey.compressedRepresentation
        )
        try householdStore.save(state)
        let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

        do {
            _ = try await client.householdRequest(
                path: "/api/v1/household/members",
                requiredOperation: "claws.list"
            )
            Issue.record("Expected invalid local cert")
        } catch HouseholdPoPError.invalidLocalCert {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(HouseholdAPIClientTestURLProtocol.capturedRequest == nil)
    }

    @Test func missingLocalCaveatBlocksHouseholdRequestBeforeNetwork() async throws {
        HouseholdAPIClientTestURLProtocol.reset()
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let storage = InMemoryHouseholdStorage()
        let householdStore = HouseholdSessionStore(storage: storage, account: "active")
        try householdStore.save(try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
        let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

        do {
            _ = try await client.householdRequest(
                path: "/api/v1/household/members",
                requiredOperation: "claws.promote"
            )
            Issue.record("Expected missing caveat")
        } catch HouseholdPoPError.missingCaveat("claws.promote") {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(HouseholdAPIClientTestURLProtocol.capturedRequest == nil)
    }

    private func makeClient(
        householdStore: HouseholdSessionStore,
        ownerKey: P256.Signing.PrivateKey
    ) -> SoyehtAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HouseholdAPIClientTestURLProtocol.self]
        let defaults = UserDefaults(suiteName: "HouseholdAPIClientTests.\(UUID().uuidString)")!
        return SoyehtAPIClient(
            session: URLSession(configuration: config),
            store: SessionStore(defaults: defaults, keychainService: "HouseholdAPIClientTests.\(UUID().uuidString)"),
            householdSessionStore: householdStore,
            ownerIdentityKeyProvider: HouseholdAPIClientOwnerKeyProvider(key: ownerKey),
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        )
    }

    private func makeActiveHouseholdState(
        householdKey: P256.Signing.PrivateKey,
        ownerKey: P256.Signing.PrivateKey,
        householdPublicKeyOverride: Data? = nil
    ) throws -> ActiveHouseholdState {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey,
            now: now
        )
        let cert = try PersonCert(cbor: certCBOR)
        return ActiveHouseholdState(
            householdId: cert.householdId,
            householdName: "Sample Home",
            householdPublicKey: householdPublicKeyOverride ?? householdPublicKey,
            endpoint: URL(string: "https://home.local:8443")!,
            ownerPersonId: cert.personId,
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "owner-key",
            personCert: cert,
            pairedAt: now,
            lastSeenAt: now
        )
    }
}
