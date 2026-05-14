import XCTest
import CryptoKit
import SoyehtCore
@testable import Soyeht

@MainActor
final class HouseholdPairingViewModelTests: XCTestCase {
    func testScanToActiveHouseholdState() async throws {
        let household = makeHouseholdState(name: "Sample Home")
        let viewModel = HouseholdPairingViewModel(displayNameProvider: { "Owner" }) { _, displayName in
            XCTAssertEqual(displayName, "Owner")
            return household
        }

        await viewModel.pairNow(url: URL(string: "soyeht://household/pair-device?v=1")!)

        XCTAssertEqual(viewModel.state, .paired(household))
    }

    func testFailureStateDoesNotActivateHousehold() async throws {
        let viewModel = HouseholdPairingViewModel(displayNameProvider: { "Owner" }) { _, _ in
            throw HouseholdPairingError.noMatchingHousehold
        }

        await viewModel.pairNow(url: URL(string: "soyeht://household/pair-device?v=1")!)

        XCTAssertEqual(viewModel.state, .failed(.noMatchingHousehold))
    }

    private func makeHouseholdState(name: String) -> ActiveHouseholdState {
        let publicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let cert = PersonCert(
            rawCBOR: Data([1, 2, 3]),
            version: 1,
            type: "person",
            householdId: "hh_test",
            personId: "p_test",
            personPublicKey: publicKey,
            displayName: "Owner",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) }.sorted { $0.operation < $1.operation },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: "hh:hh_test",
            signature: Data(repeating: 0, count: 64)
        )
        return ActiveHouseholdState(
            householdId: "hh_test",
            householdName: name,
            householdPublicKey: publicKey,
            endpoint: URL(string: "https://home.local:8443")!,
            ownerPersonId: "p_test",
            ownerPublicKey: publicKey,
            ownerKeyReference: "owner-key",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 2),
            lastSeenAt: nil
        )
    }
}

/// Tests for the free function extracted from `presentPairDeviceConfirmation`
/// in `SSHLoginView.swift`. The security contract is that the function MUST
/// throw on any failure — the deep-link path refuses to pair without a
/// fingerprint to display because the fingerprint is the operator's only
/// line of defence on a URL delivered by an untrusted sender. Closes
/// PR #61 review NIT #8.
final class PairDeviceFingerprintWordsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_714_972_800)
    private let validTTL: TimeInterval = 1_714_973_100

    func testReturnsBLAKE3DerivedWordsForValidURL() throws {
        let hhPub = Self.publicKey(byte: 0x22)
        let url = try makeValidURL(hhPub: hhPub, ttl: validTTL)

        let words = try pairDeviceFingerprintWords(for: url, now: now)

        // Pin against a direct call to `OperatorFingerprint.derive`. The
        // free function is a thin composition of `PairDeviceQR(url:now:)` +
        // `BIP39Wordlist()` + `OperatorFingerprint.derive(...)`, so the
        // BLAKE3-derived words must match the direct call byte-for-byte.
        let wordlist = try BIP39Wordlist()
        let direct = try OperatorFingerprint.derive(
            machinePublicKey: hhPub,
            wordlist: wordlist
        ).words
        XCTAssertEqual(words, direct)
        XCTAssertEqual(words.count, OperatorFingerprint.wordCount)
    }

    func testReturnsBLAKE3DerivedWordsForDevicePairingURL() throws {
        let hhPub = Self.publicKey(byte: 0x44)
        let link = HouseholdDevicePairingLink(
            endpoint: try XCTUnwrap(URL(string: "http://192.0.2.10:8091")),
            householdId: "hh_test",
            householdPublicKey: hhPub,
            householdName: "Studio"
        )
        let url = try link.url()

        let words = try pairDeviceFingerprintWords(for: url, now: now)

        let wordlist = try BIP39Wordlist()
        let direct = try OperatorFingerprint.derive(
            machinePublicKey: hhPub,
            wordlist: wordlist
        ).words
        XCTAssertEqual(words, direct)
        XCTAssertEqual(words.count, OperatorFingerprint.wordCount)
    }

    func testThrowsOnExpiredURL() throws {
        let hhPub = Self.publicKey(byte: 0x33)
        // ttl in the past relative to `now` — `PairDeviceQR` rejects with
        // `.expired`, the free function propagates the throw, the caller
        // refuses to pair. SAFETY-relevant: an attacker who replays an
        // old QR cannot bypass freshness checks.
        let url = try makeValidURL(hhPub: hhPub, ttl: now.timeIntervalSince1970 - 60)

        do {
            _ = try pairDeviceFingerprintWords(for: url, now: now)
            XCTFail("Expected throw on expired URL")
        } catch PairDeviceQRError.expired {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testThrowsOnInvalidPublicKey() throws {
        // Wrong SEC1 prefix (0x04 = uncompressed, but length 33 — invalid
        // for both compressed and uncompressed). `PairDeviceQR` rejects
        // with `.invalidHouseholdPublicKey`.
        let badKey = Data([0x04] + Array(repeating: UInt8(1), count: 32))
        let url = try makeValidURL(hhPub: badKey, ttl: validTTL)

        do {
            _ = try pairDeviceFingerprintWords(for: url, now: now)
            XCTFail("Expected throw on invalid public key")
        } catch PairDeviceQRError.invalidHouseholdPublicKey {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testThrowsOnUnsupportedScheme() throws {
        let url = try XCTUnwrap(URL(string: "theyos://household/pair-device?v=1"))

        do {
            _ = try pairDeviceFingerprintWords(for: url, now: now)
            XCTFail("Expected throw on unsupported scheme")
        } catch PairDeviceQRError.unsupportedScheme {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeValidURL(hhPub: Data, ttl: TimeInterval) throws -> URL {
        let nonce = Data(repeating: 0x07, count: 32)
        let urlString = """
        soyeht://household/pair-device\
        ?v=1\
        &hh_pub=\(hhPub.soyehtBase64URLEncodedString())\
        &nonce=\(nonce.soyehtBase64URLEncodedString())\
        &ttl=\(Int(ttl))
        """
        return try XCTUnwrap(URL(string: urlString))
    }

    /// SEC1-compressed P-256 public key derived from a deterministic
    /// 32-byte private scalar — same construction as
    /// `HouseholdTestFixtures.publicKey(byte:)` in SoyehtCore tests, but
    /// inlined because that fixture is internal to its target.
    private static func publicKey(byte: UInt8 = 1) -> Data {
        let privateKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
        return privateKey.publicKey.compressedRepresentation
    }
}
