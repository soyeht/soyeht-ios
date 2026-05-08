import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

private struct TestBonjourBrowser: HouseholdBonjourBrowsing {
    let candidate: HouseholdDiscoveryCandidate?

    func firstMatchingCandidate(for qr: PairDeviceQR, timeout: TimeInterval) async throws -> HouseholdDiscoveryCandidate {
        guard let candidate, candidate.matches(qr: qr) else {
            throw HouseholdPairingError.noMatchingHousehold
        }
        return candidate
    }
}

private struct TestOwnerIdentityProvider: OwnerIdentityKeyCreating {
    let key: P256.Signing.PrivateKey

    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        try InMemoryOwnerIdentityKey(publicKey: key.publicKey.compressedRepresentation) { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }

    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        try createOwnerIdentity(displayName: "Caio")
    }
}

private actor CapturingPairingHTTPClient: HouseholdPairingHTTPClient {
    let response: PairDeviceConfirmResponse
    private(set) var capturedEndpoint: URL?
    private(set) var capturedBody: PairDeviceConfirmRequest?

    init(response: PairDeviceConfirmResponse) {
        self.response = response
    }

    func confirmPairing(endpoint: URL, body: PairDeviceConfirmRequest) async throws -> PairDeviceConfirmResponse {
        capturedEndpoint = endpoint
        capturedBody = body
        return response
    }
}

@Suite("HouseholdPairingService")
struct HouseholdPairingServiceTests {
    @Test func pairsValidQRCodeIntoActiveHouseholdState() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x77)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100"))
        let qr = try PairDeviceQR(url: qrURL, now: now)
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerKey.publicKey.compressedRepresentation,
            now: now
        )
        let response = PairDeviceConfirmResponse(
            v: 1,
            householdId: qr.householdId,
            personId: try HouseholdIdentifiers.personIdentifier(for: ownerKey.publicKey.compressedRepresentation),
            personCertCBOR: certCBOR.soyehtBase64URLEncodedString(),
            capabilities: Array(PersonCert.requiredOwnerOperations).sorted()
        )
        let http = CapturingPairingHTTPClient(response: response)
        let storage = InMemoryHouseholdStorage()
        let service = HouseholdPairingService(
            browser: TestBonjourBrowser(candidate: HouseholdDiscoveryCandidate(
                endpoint: URL(string: "https://casa.local:8443")!,
                householdId: qr.householdId,
                householdName: "Casa Caio",
                machineId: "m_mac",
                pairingState: "device",
                shortNonce: qr.shortNonce
            )),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: http,
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            now: { now }
        )

        let state = try await service.pair(url: qrURL, displayName: "Caio")

        #expect(state.householdName == "Casa Caio")
        #expect(state.householdId == qr.householdId)
        #expect(state.ownerPersonId == response.personId)
        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == state)
        #expect(await http.capturedEndpoint == URL(string: "https://casa.local:8443")!)
        #expect(await http.capturedBody?.nonce == nonce.soyehtBase64URLEncodedString())
        #expect(await http.capturedBody?.displayName == "Caio")
    }

    @Test func invalidCertificateDoesNotActivateHousehold() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x78)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100"))
        let qr = try PairDeviceQR(url: qrURL, now: now)
        let response = PairDeviceConfirmResponse(
            v: 1,
            householdId: qr.householdId,
            personId: try HouseholdIdentifiers.personIdentifier(for: ownerKey.publicKey.compressedRepresentation),
            personCertCBOR: Data([1, 2, 3]).soyehtBase64URLEncodedString(),
            capabilities: []
        )
        let storage = InMemoryHouseholdStorage()
        let service = HouseholdPairingService(
            browser: TestBonjourBrowser(candidate: HouseholdDiscoveryCandidate(
                endpoint: URL(string: "https://casa.local:8443")!,
                householdId: qr.householdId,
                householdName: "Casa Caio",
                machineId: nil,
                pairingState: "device",
                shortNonce: qr.shortNonce
            )),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: CapturingPairingHTTPClient(response: response),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            now: { now }
        )

        do {
            _ = try await service.pair(url: qrURL, displayName: "Caio")
            Issue.record("Expected cert invalid")
        } catch HouseholdPairingError.certInvalid {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == nil)
    }
}
