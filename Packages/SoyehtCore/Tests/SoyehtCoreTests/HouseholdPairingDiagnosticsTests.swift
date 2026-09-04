import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

/// Collects the lines the pair flow would have written to `os.Logger`, so a
/// test can assert a refusal NAMED itself. Every check here is on the text a
/// device would print, because that text is the only artefact a from-scratch
/// run leaves behind.
private final class DiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var sink: HouseholdPairingLogSink {
        { [self] level, message in
            lock.lock()
            defer { lock.unlock() }
            lines.append("\(level.rawValue) \(message)")
        }
    }

    var captured: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func line(containing needle: String) -> String? {
        captured.first { $0.contains(needle) }
    }
}

private struct StubBrowser: HouseholdBonjourBrowsing {
    let candidate: HouseholdDiscoveryCandidate

    func firstMatchingCandidate(for qr: PairDeviceQR, timeout: TimeInterval) async throws -> HouseholdDiscoveryCandidate {
        candidate
    }
}

private struct StubOwnerIdentityProvider: OwnerIdentityKeyCreating {
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

private struct StubPairingHTTPClient: HouseholdPairingHTTPClient {
    let response: PairDeviceConfirmResponse

    func confirmPairing(endpoint: URL, body: PairDeviceConfirmRequest) async throws -> PairDeviceConfirmResponse {
        response
    }
}

@Suite("HouseholdPairingDiagnostics")
struct HouseholdPairingDiagnosticsTests {
    /// The Mac's clock when it mints the cert. The engine signs
    /// `not_before = issued_at`, both at whole-second resolution.
    private static let macNow = Date(timeIntervalSince1970: 1_714_972_800)

    /// The engine's real certificate shape, refused by a phone one second
    /// behind the Mac. Every other fixture in this package backdates
    /// `not_before` by 60 s, so before this test nothing exercised the only
    /// time-dependent guard in `PersonCert.validate` at all — and a failure
    /// here reached the user as the same catch-all sentence as every other
    /// error.
    @Test func engineShapedCertRefusedByATrailingClockNamesTheGuardAndTheSkew() async throws {
        let phoneNow = Self.macNow.addingTimeInterval(-1)
        let recorder = DiagnosticsRecorder()
        let fixture = try Fixture(certNow: Self.macNow, notBefore: Self.macNow)
        let store = HouseholdSessionStore(storage: fixture.storage, account: "active")

        await #expect(throws: HouseholdPairingError.certInvalid) {
            try await fixture.service(now: phoneNow, log: recorder.sink).pair(url: fixture.qrURL, displayName: "Owner")
        }

        // The measurement that decides the hypothesis: the cert is one second
        // in this phone's future.
        let validity = try #require(recorder.line(containing: "pair.cert.validity"))
        #expect(validity.contains("notBefore=1714972800"))
        #expect(validity.contains("issuedAt=1714972800"))
        #expect(validity.contains("now=1714972799"))
        #expect(validity.contains("skewMs=-1000"))

        // And the refusal names which of PersonCert's fifteen rejections fired.
        #expect(recorder.line(containing: "pair.certInvalid guard=personCert case=invalidValidityWindow") != nil)
        #expect(recorder.line(containing: "guard=catchAll") == nil)
        #expect(try store.load() == nil)
    }

    /// Control for the test above: the same engine-shaped cert pairs the moment
    /// the phone's clock agrees with the Mac's. Without this, a broken fixture
    /// would look like a proven hypothesis.
    @Test func theSameEngineShapedCertPairsWhenTheClocksAgree() async throws {
        let recorder = DiagnosticsRecorder()
        let fixture = try Fixture(certNow: Self.macNow, notBefore: Self.macNow)

        let state = try await fixture.service(now: Self.macNow, log: recorder.sink)
            .pair(url: fixture.qrURL, displayName: "Owner")

        #expect(state.householdId == fixture.householdId)
        let validity = try #require(recorder.line(containing: "pair.cert.validity"))
        #expect(validity.contains("skewMs=0"))
        #expect(recorder.line(containing: "pair.certInvalid") == nil)
    }

    /// A cert body that is not decodable must not reach the anonymous
    /// catch-all either — the line has to say what failed to parse.
    @Test func anUnparseableCertBodyNamesItsDecodeFailure() async throws {
        let recorder = DiagnosticsRecorder()
        let fixture = try Fixture(
            certNow: Self.macNow,
            notBefore: Self.macNow,
            certCBOROverride: Data([0x01, 0x02, 0x03])
        )

        await #expect(throws: HouseholdPairingError.certInvalid) {
            try await fixture.service(now: Self.macNow, log: recorder.sink).pair(url: fixture.qrURL, displayName: "Owner")
        }

        #expect(recorder.line(containing: "pair.certInvalid guard=cborDecode case=trailingBytes") != nil)
        #expect(recorder.line(containing: "guard=catchAll") == nil)
    }
}

private struct Fixture {
    let qrURL: URL
    let householdId: String
    let storage = InMemoryHouseholdStorage()
    private let ownerKey: P256.Signing.PrivateKey
    private let candidate: HouseholdDiscoveryCandidate
    private let response: PairDeviceConfirmResponse

    init(certNow: Date, notBefore: Date, certCBOROverride: Data? = nil) throws {
        let householdKey = P256.Signing.PrivateKey()
        ownerKey = P256.Signing.PrivateKey()
        let hhPub = householdKey.publicKey.compressedRepresentation
        let nonce = HouseholdTestFixtures.nonce(byte: 0x42)
        qrURL = try #require(URL(string: "soyeht://household/pair-device?v=1&hh_pub=\(hhPub.soyehtBase64URLEncodedString())&nonce=\(nonce.soyehtBase64URLEncodedString())&ttl=1714973100&m_cert_fp=\(Data(repeating: 0xAB, count: 32).soyehtBase64URLEncodedString())&crit=m_cert_fp"))
        let qr = try PairDeviceQR(url: qrURL, now: certNow)
        householdId = qr.householdId
        let certCBOR = try certCBOROverride ?? HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerKey.publicKey.compressedRepresentation,
            now: certNow,
            notBefore: notBefore
        )
        candidate = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://home.local:8443")!,
            householdId: qr.householdId,
            householdName: "Sample Home",
            machineId: "m_mac",
            pairingState: "device",
            shortNonce: qr.shortNonce
        )
        response = PairDeviceConfirmResponse(
            v: 1,
            householdId: qr.householdId,
            personId: try HouseholdIdentifiers.personIdentifier(for: ownerKey.publicKey.compressedRepresentation),
            personCertCBOR: certCBOR.soyehtBase64URLEncodedString(),
            capabilities: certCBOROverride == nil ? Array(PersonCert.requiredOwnerOperations).sorted() : []
        )
    }

    func service(now: Date, log: @escaping HouseholdPairingLogSink) -> HouseholdPairingService {
        HouseholdPairingService(
            browser: StubBrowser(candidate: candidate),
            keyProvider: StubOwnerIdentityProvider(key: ownerKey),
            httpClient: StubPairingHTTPClient(response: response),
            sessionStore: HouseholdSessionStore(storage: storage, account: "active"),
            rosterStorage: InMemoryHouseholdStorage(),
            rosterAccount: "roster",
            now: { now },
            log: log
        )
    }
}
