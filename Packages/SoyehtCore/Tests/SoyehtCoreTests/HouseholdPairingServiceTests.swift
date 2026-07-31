import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

/// Records the `timeout` the service passes to the browser, so a test can prove
/// the migrated call site uses the `OnboardingConfig` value (and that it equals
/// the pre-migration literal).
private actor TimeoutRecorder {
    private(set) var captured: TimeInterval?
    func record(_ timeout: TimeInterval) { captured = timeout }
}

private struct TestBonjourBrowser: HouseholdBonjourBrowsing {
    let candidate: HouseholdDiscoveryCandidate?
    var recorder: TimeoutRecorder? = nil

    func firstMatchingCandidate(for qr: PairDeviceQR, timeout: TimeInterval) async throws -> HouseholdDiscoveryCandidate {
        await recorder?.record(timeout)
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
        try createOwnerIdentity(displayName: "Owner")
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
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())&crit=m_cert_fp"))
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
        let rosterStorage = InMemoryHouseholdStorage()
        let service = HouseholdPairingService(
            browser: TestBonjourBrowser(candidate: HouseholdDiscoveryCandidate(
                endpoint: URL(string: "https://home.local:8443")!,
                householdId: qr.householdId,
                householdName: "Sample Home",
                machineId: "m_mac",
                pairingState: "device",
                shortNonce: qr.shortNonce
            )),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: http,
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: rosterStorage,
            rosterAccount: "roster",
            now: { now }
        )

        let state = try await service.pair(url: qrURL, displayName: "Owner")

        #expect(state.householdName == "Sample Home")
        #expect(state.householdId == qr.householdId)
        #expect(state.ownerPersonId == response.personId)
        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == state)
        // The pair flow must leave the roster store rooted on the QR's machine
        // cert fingerprint. Read it back through a *fresh* store over the same
        // secure storage so this proves persistence, not in-memory bookkeeping.
        let seeded = await RosterProjectionStore(
            expectedHouseholdId: qr.householdId,
            householdPublicKey: qr.householdPublicKey,
            storage: rosterStorage,
            account: "roster"
        ).load()
        #expect(seeded == .pendingAnchor(qrAnchorFingerprint: qr.machineCertFingerprint))
        #expect(await http.capturedEndpoint == URL(string: "https://home.local:8443")!)
        #expect(await http.capturedBody?.nonce == nonce.soyehtBase64URLEncodedString())
        #expect(await http.capturedBody?.displayName == "Owner")
    }

    @Test func discoveryTimeoutComesFromOnboardingConfigDefault() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x77)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())&crit=m_cert_fp"))
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
        let recorder = TimeoutRecorder()
        let storage = InMemoryHouseholdStorage()
        let service = HouseholdPairingService(
            browser: TestBonjourBrowser(
                candidate: HouseholdDiscoveryCandidate(
                    endpoint: URL(string: "https://home.local:8443")!,
                    householdId: qr.householdId,
                    householdName: "Sample Home",
                    machineId: "m_mac",
                    pairingState: "device",
                    shortNonce: qr.shortNonce
                ),
                recorder: recorder
            ),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: CapturingPairingHTTPClient(response: response),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: InMemoryHouseholdStorage(),
            rosterAccount: "roster",
            now: { now }
        )

        _ = try await service.pair(url: qrURL, displayName: "Owner")

        // Behavior-equivalent migration: the Bonjour discovery timeout now comes
        // from the OnboardingConfig SSOT, byte-for-byte the same value the call
        // site passed as a literal before the migration.
        let captured = await recorder.captured
        #expect(captured == OnboardingConfig.default.householdDiscoveryTimeout)
        #expect(captured == 10.0)
    }

    @Test func directHostPairingPreservesHouseholdName() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x79)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&house_name=Retry%20Home&host=192.0.2.10:8101&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())&crit=m_cert_fp"))
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
            browser: TestBonjourBrowser(candidate: nil),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: http,
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: InMemoryHouseholdStorage(),
            rosterAccount: "roster",
            now: { now }
        )

        let state = try await service.pair(url: qrURL, displayName: "Owner")

        #expect(state.householdName == "Retry Home")
        #expect(await http.capturedEndpoint == URL(string: "http://192.0.2.10:8101")!)
    }

    @Test func invalidCertificateDoesNotActivateHousehold() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x78)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())&crit=m_cert_fp"))
        let qr = try PairDeviceQR(url: qrURL, now: now)
        let response = PairDeviceConfirmResponse(
            v: 1,
            householdId: qr.householdId,
            personId: try HouseholdIdentifiers.personIdentifier(for: ownerKey.publicKey.compressedRepresentation),
            personCertCBOR: Data([1, 2, 3]).soyehtBase64URLEncodedString(),
            capabilities: []
        )
        let storage = InMemoryHouseholdStorage()
        let rosterStorage = InMemoryHouseholdStorage()
        let service = HouseholdPairingService(
            browser: TestBonjourBrowser(candidate: HouseholdDiscoveryCandidate(
                endpoint: URL(string: "https://home.local:8443")!,
                householdId: qr.householdId,
                householdName: "Sample Home",
                machineId: nil,
                pairingState: "device",
                shortNonce: qr.shortNonce
            )),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: CapturingPairingHTTPClient(response: response),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: rosterStorage,
            rosterAccount: "roster",
            now: { now }
        )

        do {
            _ = try await service.pair(url: qrURL, displayName: "Owner")
            Issue.record("Expected cert invalid")
        } catch HouseholdPairingError.certInvalid {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == nil)
        // The anchor is seeded strictly after `cert.validate` accepts the cert,
        // so a rejected cert must leave the roster store not merely unusable
        // but unwritten — `.absent` alone would also match a written-then-
        // rejected blob.
        #expect(rosterStorage.load(account: "roster") == nil)
        let rosterState = await RosterProjectionStore(
            expectedHouseholdId: qr.householdId,
            householdPublicKey: qr.householdPublicKey,
            storage: rosterStorage,
            account: "roster"
        ).load()
        #expect(rosterState == .absent)
    }

    @Test func rosterAnchorStorageFailureIsReportedAsStorageFailedNotCertInvalid() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x7A)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())&crit=m_cert_fp"))
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
        // Separate storages: only the roster write is refused, so a failure can
        // be attributed to the roster store rather than to the session store.
        let storage = InMemoryHouseholdStorage()
        let rosterStorage = InMemoryHouseholdStorage()
        rosterStorage.shouldFailSave = true
        let service = HouseholdPairingService(
            browser: TestBonjourBrowser(candidate: HouseholdDiscoveryCandidate(
                endpoint: URL(string: "https://home.local:8443")!,
                householdId: qr.householdId,
                householdName: "Sample Home",
                machineId: "m_mac",
                pairingState: "device",
                shortNonce: qr.shortNonce
            )),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: CapturingPairingHTTPClient(response: response),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: rosterStorage,
            rosterAccount: "roster",
            now: { now }
        )

        do {
            _ = try await service.pair(url: qrURL, displayName: "Owner")
            Issue.record("Expected storage failure")
        } catch HouseholdPairingError.storageFailed {
        } catch HouseholdPairingError.certInvalid {
            Issue.record("A refused roster write must not be reported as certInvalid")
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        // Seeding precedes the session save, so a refused anchor write must
        // leave no active household behind.
        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == nil)
        #expect(rosterStorage.load(account: "roster") == nil)
    }

    @Test func sessionSaveFailureAfterSeedLeavesPendingAnchorAndRetryIsIdempotent() async throws {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x7B)
        let qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())&crit=m_cert_fp"))
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
        // Mirror image of the previous test: only the session write is refused.
        let storage = InMemoryHouseholdStorage()
        storage.shouldFailSave = true
        let rosterStorage = InMemoryHouseholdStorage()
        let service = HouseholdPairingService(
            browser: TestBonjourBrowser(candidate: HouseholdDiscoveryCandidate(
                endpoint: URL(string: "https://home.local:8443")!,
                householdId: qr.householdId,
                householdName: "Sample Home",
                machineId: "m_mac",
                pairingState: "device",
                shortNonce: qr.shortNonce
            )),
            keyProvider: TestOwnerIdentityProvider(key: ownerKey),
            httpClient: CapturingPairingHTTPClient(response: response),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: rosterStorage,
            rosterAccount: "roster",
            now: { now }
        )

        do {
            _ = try await service.pair(url: qrURL, displayName: "Owner")
            Issue.record("Expected storage failure")
        } catch HouseholdPairingError.storageFailed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == nil)
        // The orphaned anchor is inert, not corrupt: no session reads it, and it
        // stays recoverable for the retry below.
        let afterFailure = await RosterProjectionStore(
            expectedHouseholdId: qr.householdId,
            householdPublicKey: qr.householdPublicKey,
            storage: rosterStorage,
            account: "roster"
        ).load()
        #expect(afterFailure == .pendingAnchor(qrAnchorFingerprint: qr.machineCertFingerprint))
        let seededBytes = rosterStorage.load(account: "roster")

        storage.shouldFailSave = false
        let state = try await service.pair(url: qrURL, displayName: "Owner")

        #expect(try HouseholdSessionStore(storage: storage, account: "active").load() == state)
        let afterRetry = await RosterProjectionStore(
            expectedHouseholdId: qr.householdId,
            householdPublicKey: qr.householdPublicKey,
            storage: rosterStorage,
            account: "roster"
        ).load()
        #expect(afterRetry == .pendingAnchor(qrAnchorFingerprint: qr.machineCertFingerprint))
        // Idempotent at the byte level: re-pairing against the same QR re-reads
        // the persisted anchor and returns without rewriting it.
        #expect(rosterStorage.load(account: "roster") == seededBytes)
    }
}
