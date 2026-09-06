import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

/// Exercise the selected endpoint through confirm and actual session storage.
@Suite("PairingReachedEndpoint")
struct PairingReachedEndpointTests {
    static let macNow = Date(timeIntervalSince1970: 1_714_972_800)
    private let installation = PairingInstallIdentity(.dev)
    private let lan = URL(string: "http://192.168.1.20:8101")!

    @Test func pureWiFiUsesTheReachedLANAddressThroughPersistence() async throws {
        let fixture = try EndpointFixture(hostFallback: "100.64.0.10:8101")
        let recorder = EndpointRecorder()
        let paired = try await fixture.service(recorder: recorder).pair(
            url: fixture.qrURL, displayName: "Owner", reachedEndpoint: lan,
            phoneNetwork: .init(hasTailnetAddress: false), installation: installation
        )
        #expect(recorder.endpoint == lan)
        #expect(paired.endpoint == lan)
        #expect(try fixture.persisted()?.endpoint == lan)
    }

    @Test func test_keepsTheTailnetAddressWhenThePhoneIsOnTheTailnet() async throws {
        let fixture = try EndpointFixture(hostFallback: "100.64.0.10:8101")
        let recorder = EndpointRecorder()
        let paired = try await fixture.service(recorder: recorder).pair(
            url: fixture.qrURL, displayName: "Owner", reachedEndpoint: lan,
            phoneNetwork: .init(hasTailnetAddress: true), installation: installation
        )
        let tailnet = URL(string: "http://100.64.0.10:8101")!
        #expect(recorder.endpoint == tailnet)
        #expect(paired.endpoint == tailnet)
        #expect(try fixture.persisted()?.endpoint == tailnet)
    }

    @Test(arguments: [true, false, nil] as [Bool?])
    func embeddedQROfferReachesPersistenceWithPhoneEvidence(capability: Bool?) async throws {
        let fixture = try EndpointFixture(hostFallback: "192.168.1.20:8101")
        let tailnet = URL(string: "http://100.64.0.10:8101")!
        let offer = PairingAddressOffer(installation: installation, generation: "listeners", candidates: [
            PairingAddressCandidate(url: lan, transport: .localNetwork, operations: [.firstOwner], availability: .listening),
            PairingAddressCandidate(url: tailnet, transport: .tailnet, operations: [.firstOwner], availability: .listening),
        ])
        let qr = try PairingLinkAddresses.attaching(offer, to: fixture.qrURL)
        let recorder = EndpointRecorder()
        let paired = try await fixture.service(recorder: recorder).pair(
            url: qr, displayName: "Owner", reachedEndpoint: lan,
            phoneNetwork: .init(hasTailnetAddress: capability), installation: installation)
        let expected = capability == false ? lan : tailnet
        #expect(recorder.endpoint == expected)
        #expect(paired.endpoint == expected)
        #expect(try fixture.persisted()?.endpoint == expected)
    }

    @Test func theLinksHostIsUsedWhenTheCallerReachedNothing() async throws {
        let fixture = try EndpointFixture(hostFallback: "100.64.0.10:8101")
        let recorder = EndpointRecorder()
        _ = try await fixture.service(recorder: recorder).pair(
            url: fixture.qrURL, displayName: "Owner",
            phoneNetwork: .init(hasTailnetAddress: true), installation: installation
        )
        #expect(recorder.endpoint?.host() == "100.64.0.10")
    }

    @Test func withNoHostAndNoReachedAddressDiscoverySuppliesTheCandidate() async throws {
        let fixture = try EndpointFixture(hostFallback: nil)
        let recorder = EndpointRecorder()
        _ = try await fixture.service(recorder: recorder).pair(
            url: fixture.qrURL, displayName: "Owner",
            phoneNetwork: .init(hasTailnetAddress: false), installation: installation
        )
        #expect(recorder.endpoint?.host() == "discovered.local")
    }

    @Test func theChosenAddressSaysWhyItWasSelected() async throws {
        let fixture = try EndpointFixture(hostFallback: "100.64.0.10:8101")
        let log = LineRecorder()
        _ = try await fixture.service(recorder: EndpointRecorder(), log: log.sink).pair(
            url: fixture.qrURL, displayName: "Owner", reachedEndpoint: lan,
            phoneNetwork: .init(hasTailnetAddress: false), installation: installation
        )
        #expect(log.line(containing: "pair.endpoint source=localNetworkFallback host=192.168.1.20") != nil)
    }
}

// MARK: - Doubles

private final class EndpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: URL?

    var endpoint: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ url: URL) {
        lock.lock()
        recorded = url
        lock.unlock()
    }
}

private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var sink: HouseholdPairingLogSink {
        { [self] level, message in
            lock.lock()
            defer { lock.unlock() }
            lines.append("\(level.rawValue) \(message)")
        }
    }

    func line(containing needle: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lines.first { $0.contains(needle) }
    }
}

private struct RecordingPairingHTTPClient: HouseholdPairingHTTPClient {
    let response: PairDeviceConfirmResponse
    let recorder: EndpointRecorder

    func confirmPairing(endpoint: URL, body: PairDeviceConfirmRequest) async throws -> PairDeviceConfirmResponse {
        recorder.record(endpoint)
        return response
    }
}

private struct FixedBrowser: HouseholdBonjourBrowsing {
    let candidate: HouseholdDiscoveryCandidate

    func firstMatchingCandidate(for qr: PairDeviceQR, timeout: TimeInterval) async throws -> HouseholdDiscoveryCandidate {
        candidate
    }
}

private struct FixedOwnerIdentityProvider: OwnerIdentityKeyCreating {
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

private struct EndpointFixture {
    let qrURL: URL
    private let ownerKey: P256.Signing.PrivateKey
    private let candidate: HouseholdDiscoveryCandidate
    private let response: PairDeviceConfirmResponse
    private let storage = InMemoryHouseholdStorage()

    init(hostFallback: String?) throws {
        let householdKey = P256.Signing.PrivateKey()
        ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x42)
        var raw = "soyeht://household/pair-device?v=1"
            + "&hh_pub=\(hhPub.soyehtBase64URLEncodedString())"
            + "&nonce=\(nonce.soyehtBase64URLEncodedString())"
            + "&ttl=1714973100"
            + "&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())"
            + "&crit=m_cert_fp"
        if let hostFallback {
            raw += "&host=\(hostFallback)"
        }
        qrURL = try #require(URL(string: raw))
        let qr = try PairDeviceQR(url: qrURL, now: PairingReachedEndpointTests.macNow)
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerKey.publicKey.compressedRepresentation,
            now: PairingReachedEndpointTests.macNow,
            notBefore: PairingReachedEndpointTests.macNow
        )
        candidate = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "http://discovered.local:8101")!,
            householdId: qr.householdId,
            householdName: "Sample Home",
            machineId: "m_mac",
            pairingState: "device",
            shortNonce: qr.shortNonce
        )
        response = PairDeviceConfirmResponse(
            v: 1,
            householdId: qr.householdId,
            personId: try HouseholdIdentifiers.personIdentifier(
                for: ownerKey.publicKey.compressedRepresentation
            ),
            personCertCBOR: certCBOR.soyehtBase64URLEncodedString(),
            capabilities: Array(PersonCert.requiredOwnerOperations).sorted()
        )
    }

    func persisted() throws -> ActiveHouseholdState? {
        try HouseholdSessionStore(storage: storage, account: "active").load()
    }

    func service(
        recorder: EndpointRecorder,
        log: @escaping HouseholdPairingLogSink = { _, _ in }
    ) -> HouseholdPairingService {
        HouseholdPairingService(
            browser: FixedBrowser(candidate: candidate),
            keyProvider: FixedOwnerIdentityProvider(key: ownerKey),
            httpClient: RecordingPairingHTTPClient(response: response, recorder: recorder),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: InMemoryHouseholdStorage(),
            rosterAccount: "roster",
            now: { PairingReachedEndpointTests.macNow },
            log: log
        )
    }
}
