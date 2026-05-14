import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

private struct DevicePairingIdentityProvider: OwnerIdentityKeyCreating {
    let key: P256.Signing.PrivateKey

    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        try InMemoryOwnerIdentityKey(publicKey: key.publicKey.compressedRepresentation, keyReference: "device-key") { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }

    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        try createOwnerIdentity(displayName: "Device")
    }
}

private actor ApprovingDevicePairingHTTPClient: HouseholdDevicePairingHTTPClient {
    let householdPrivateKey: P256.Signing.PrivateKey
    let ownerPrivateKey: P256.Signing.PrivateKey
    let link: HouseholdDevicePairingLink
    let now: Date

    private(set) var capturedDevicePublicKey: Data?
    private(set) var capturedDeviceName: String?
    private(set) var capturedPlatform: String?

    init(
        householdPrivateKey: P256.Signing.PrivateKey,
        ownerPrivateKey: P256.Signing.PrivateKey,
        link: HouseholdDevicePairingLink,
        now: Date
    ) {
        self.householdPrivateKey = householdPrivateKey
        self.ownerPrivateKey = ownerPrivateKey
        self.link = link
        self.now = now
    }

    func requestPairing(
        endpoint: URL,
        devicePublicKey: Data,
        deviceName: String,
        platform: String
    ) async throws -> DevicePairingRequestResponse {
        #expect(endpoint == link.endpoint)
        capturedDevicePublicKey = devicePublicKey
        capturedDeviceName = deviceName
        capturedPlatform = platform
        return DevicePairingRequestResponse(
            version: 1,
            requestId: "req_test",
            token: "token_test",
            expiresAt: UInt64(now.timeIntervalSince1970 + 60)
        )
    }

    func pollPairing(
        endpoint: URL,
        requestId: String,
        token: String
    ) async throws -> DevicePairingPollResponse {
        #expect(endpoint == link.endpoint)
        #expect(requestId == "req_test")
        #expect(token == "token_test")
        let devicePublicKey = try #require(capturedDevicePublicKey)
        let ownerPublicKey = ownerPrivateKey.publicKey.compressedRepresentation
        let personCertCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdPrivateKey,
            personPublicKey: ownerPublicKey,
            householdId: link.householdId,
            now: now
        )
        let personCert = try PersonCert(cbor: personCertCBOR)
        let ownerIdentity = try InMemoryOwnerIdentityKey(publicKey: ownerPublicKey, keyReference: "owner-key") { payload in
            try self.ownerPrivateKey.signature(for: payload).rawRepresentation
        }
        let deviceCertCBOR = try DeviceCert.signedCBOR(
            householdId: link.householdId,
            personCert: personCert,
            devicePublicKey: devicePublicKey,
            deviceName: capturedDeviceName ?? "Test iPhone",
            platform: capturedPlatform ?? "ios",
            issuedAt: now,
            signer: ownerIdentity
        )
        return DevicePairingPollResponse(
            version: 1,
            status: "approved",
            householdId: link.householdId,
            personId: personCert.personId,
            personCertCBOR: personCertCBOR.soyehtBase64URLEncodedString(),
            deviceCertCBOR: deviceCertCBOR.soyehtBase64URLEncodedString(),
            capabilities: Array(PersonCert.requiredOwnerOperations).sorted()
        )
    }

    func approvePairing(
        endpoint: URL,
        requestId: String,
        deviceCertCBOR: Data,
        authorization: String
    ) async throws -> DevicePairingApprovalAck {
        Issue.record("pair(link:) should not call approvePairing")
        return DevicePairingApprovalAck(version: 1)
    }
}

@Suite("HouseholdDevicePairingService")
struct HouseholdDevicePairingServiceTests {
    @Test func deviceCertIsSignedByOwnerAndValidates() throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let deviceKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let personCertCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey,
            householdId: householdId,
            now: now
        )
        let personCert = try PersonCert(cbor: personCertCBOR)
        let ownerIdentity = try InMemoryOwnerIdentityKey(publicKey: ownerPublicKey, keyReference: "owner-key") { payload in
            try ownerKey.signature(for: payload).rawRepresentation
        }

        let deviceCertCBOR = try DeviceCert.signedCBOR(
            householdId: householdId,
            personCert: personCert,
            devicePublicKey: deviceKey.publicKey.compressedRepresentation,
            deviceName: "Test iPhone",
            platform: "ios",
            issuedAt: now,
            signer: ownerIdentity
        )

        let cert = try DeviceCert(cbor: deviceCertCBOR)
        try cert.validate(
            householdId: householdId,
            ownerPersonId: personCert.personId,
            ownerPersonPublicKey: ownerPublicKey,
            now: now
        )
        let derivedDeviceId = try DeviceCert.deriveDeviceId(for: deviceKey.publicKey.compressedRepresentation)
        #expect(cert.deviceId == derivedDeviceId)
        #expect(cert.deviceName == "Test iPhone")
    }

    @Test func approvedDevicePairingPersistsDelegatedHouseholdSession() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let deviceKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)
        let link = HouseholdDevicePairingLink(
            endpoint: URL(string: "https://household.example.test")!,
            householdId: householdId,
            householdPublicKey: householdPublicKey,
            householdName: "Example Home"
        )
        let http = ApprovingDevicePairingHTTPClient(
            householdPrivateKey: householdKey,
            ownerPrivateKey: ownerKey,
            link: link,
            now: now
        )
        let storage = InMemoryHouseholdStorage()
        let store = HouseholdSessionStore(storage: storage, account: "active")
        let service = HouseholdDevicePairingService(
            keyProvider: DevicePairingIdentityProvider(key: deviceKey),
            httpClient: http,
            sessionStore: store,
            now: { now },
            sleeper: { _ in }
        )

        let state = try await service.pair(link: link, deviceName: "Test iPhone")

        #expect(state.householdId == householdId)
        #expect(state.householdName == "Example Home")
        #expect(state.isDelegatedDevice)
        #expect(state.ownerPublicKey == ownerKey.publicKey.compressedRepresentation)
        #expect(state.signingPublicKey == deviceKey.publicKey.compressedRepresentation)
        #expect(state.signingKeyReference == "device-key")
        #expect(try store.load() == state)
        #expect(await http.capturedDeviceName == "Test iPhone")
        #expect(await http.capturedPlatform == "ios")
    }

    @Test func devicePairingLinkRoundTripsWithoutHostSpecificData() throws {
        let householdKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let link = HouseholdDevicePairingLink(
            endpoint: URL(string: "https://household.example.test")!,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey),
            householdPublicKey: householdPublicKey,
            householdName: "Example Home"
        )

        let decoded = try HouseholdDevicePairingLink(url: try link.url())

        #expect(decoded.endpoint == link.endpoint)
        #expect(decoded.householdId == link.householdId)
        #expect(decoded.householdPublicKey == link.householdPublicKey)
        #expect(decoded.householdName == "Example Home")
    }
}
