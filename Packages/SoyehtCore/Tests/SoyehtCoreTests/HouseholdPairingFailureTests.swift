import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

private struct FailureMatrixBrowser: HouseholdBonjourBrowsing {
    let candidate: HouseholdDiscoveryCandidate?
    let error: Error?

    func firstMatchingCandidate(for qr: PairDeviceQR, timeout: TimeInterval) async throws -> HouseholdDiscoveryCandidate {
        if let error { throw error }
        guard let candidate, candidate.matches(qr: qr) else {
            throw HouseholdPairingError.noMatchingHousehold
        }
        return candidate
    }
}

private struct FailureMatrixOwnerIdentityProvider: OwnerIdentityKeyCreating {
    let key: P256.Signing.PrivateKey
    let error: Error?

    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        if let error { throw error }
        return try InMemoryOwnerIdentityKey(publicKey: key.publicKey.compressedRepresentation) { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }

    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        try createOwnerIdentity(displayName: "Caio")
    }
}

private struct FailureMatrixHTTPClient: HouseholdPairingHTTPClient {
    let response: PairDeviceConfirmResponse?
    let error: Error?

    func confirmPairing(endpoint: URL, body: PairDeviceConfirmRequest) async throws -> PairDeviceConfirmResponse {
        if let error { throw error }
        return response!
    }
}

@Suite("HouseholdPairingFailureMatrix")
struct HouseholdPairingFailureTests {
    @Test func invalidAndExpiredQRsDoNotActivateHousehold() async throws {
        try await expectFailure(
            url: URL(string: "soyeht://household/pair-device?v=1")!,
            expected: .invalidQR
        )

        let fixture = try makeFixture()
        let expiredURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(fixture.householdPublicKey.soyehtBase64URLEncodedString())&nonce=\(fixture.nonce.soyehtBase64URLEncodedString())&ttl=1714972700"))
        try await expectFailure(url: expiredURL, expected: .expiredQR)
    }

    @Test func discoveryIdentityNetworkRejectedCertAndStorageFailuresDoNotActivateHousehold() async throws {
        let fixture = try makeFixture()

        try await expectFailure(
            fixture: fixture,
            browser: FailureMatrixBrowser(candidate: nil, error: nil),
            expected: .noMatchingHousehold
        )
        try await expectFailure(
            fixture: fixture,
            keyProvider: FailureMatrixOwnerIdentityProvider(key: fixture.ownerKey, error: OwnerIdentityKeyError.secureEnclaveUnavailable),
            expected: .identityKeyUnavailable
        )
        try await expectFailure(
            fixture: fixture,
            keyProvider: FailureMatrixOwnerIdentityProvider(key: fixture.ownerKey, error: OwnerIdentityKeyError.biometryCanceled),
            expected: .biometryCanceled
        )
        try await expectFailure(
            fixture: fixture,
            httpClient: FailureMatrixHTTPClient(response: nil, error: URLError(.networkConnectionLost)),
            expected: .networkUnavailable
        )
        try await expectFailure(
            fixture: fixture,
            httpClient: FailureMatrixHTTPClient(response: nil, error: HouseholdPairingError.firstOwnerAlreadyPaired),
            expected: .firstOwnerAlreadyPaired
        )
        try await expectFailure(
            fixture: fixture,
            httpClient: FailureMatrixHTTPClient(response: fixture.responseWithInvalidCert, error: nil),
            expected: .certInvalid
        )

        let failingStorage = InMemoryHouseholdStorage()
        failingStorage.shouldFailSave = true
        try await expectFailure(
            fixture: fixture,
            sessionStore: HouseholdSessionStore(storage: failingStorage, account: "active"),
            expected: .storageFailed
        )
    }

    private func expectFailure(
        url: URL,
        expected: HouseholdPairingError
    ) async throws {
        let storage = InMemoryHouseholdStorage()
        let service = HouseholdPairingService(
            browser: FailureMatrixBrowser(candidate: nil, error: nil),
            keyProvider: FailureMatrixOwnerIdentityProvider(key: P256.Signing.PrivateKey(), error: nil),
            httpClient: FailureMatrixHTTPClient(response: nil, error: nil),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        )
        do {
            _ = try await service.pair(url: url, displayName: "Caio")
            Issue.record("Expected \(expected)")
        } catch let error as HouseholdPairingError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == nil)
    }

    private func expectFailure(
        fixture: PairingFailureFixture,
        browser: FailureMatrixBrowser? = nil,
        keyProvider: FailureMatrixOwnerIdentityProvider? = nil,
        httpClient: FailureMatrixHTTPClient? = nil,
        sessionStore: HouseholdSessionStore? = nil,
        expected: HouseholdPairingError
    ) async throws {
        let storage = InMemoryHouseholdStorage()
        let resolvedStore = sessionStore ?? HouseholdSessionStore(storage: storage, account: "active")
        let service = HouseholdPairingService(
            browser: browser ?? FailureMatrixBrowser(candidate: fixture.candidate, error: nil),
            keyProvider: keyProvider ?? FailureMatrixOwnerIdentityProvider(key: fixture.ownerKey, error: nil),
            httpClient: httpClient ?? FailureMatrixHTTPClient(response: fixture.validResponse, error: nil),
            sessionStore: resolvedStore,
            now: { fixture.now }
        )
        do {
            _ = try await service.pair(url: fixture.qrURL, displayName: "Caio")
            Issue.record("Expected \(expected)")
        } catch let error as HouseholdPairingError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(try resolvedStore.load() == nil)
    }

    private func makeFixture() throws -> PairingFailureFixture {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x90)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(householdPublicKey.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100"))
        let qr = try PairDeviceQR(url: qrURL, now: now)
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerKey.publicKey.compressedRepresentation,
            now: now
        )
        let personId = try HouseholdIdentifiers.personIdentifier(for: ownerKey.publicKey.compressedRepresentation)
        let validResponse = PairDeviceConfirmResponse(
            v: 1,
            householdId: qr.householdId,
            personId: personId,
            personCertCBOR: certCBOR.soyehtBase64URLEncodedString(),
            capabilities: Array(PersonCert.requiredOwnerOperations).sorted()
        )
        let responseWithInvalidCert = PairDeviceConfirmResponse(
            v: 1,
            householdId: qr.householdId,
            personId: personId,
            personCertCBOR: Data([1, 2, 3]).soyehtBase64URLEncodedString(),
            capabilities: []
        )
        return PairingFailureFixture(
            now: now,
            householdPublicKey: householdPublicKey,
            nonce: nonce,
            qrURL: qrURL,
            ownerKey: ownerKey,
            candidate: HouseholdDiscoveryCandidate(
                endpoint: URL(string: "https://casa.local:8443")!,
                householdId: qr.householdId,
                householdName: "Casa Caio",
                machineId: "m_mac",
                pairingState: "open",
                shortNonce: qr.shortNonce
            ),
            validResponse: validResponse,
            responseWithInvalidCert: responseWithInvalidCert
        )
    }
}

private struct PairingFailureFixture {
    let now: Date
    let householdPublicKey: Data
    let nonce: Data
    let qrURL: URL
    let ownerKey: P256.Signing.PrivateKey
    let candidate: HouseholdDiscoveryCandidate
    let validResponse: PairDeviceConfirmResponse
    let responseWithInvalidCert: PairDeviceConfirmResponse
}
