import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdBonjourBrowser")
struct HouseholdBonjourBrowserTests {
    @Test func candidateMatchesHouseholdIdDevicePairingAndShortNonce() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x61)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x62)
        let qr = PairDeviceQR(
            version: 1,
            householdPublicKey: hhPub,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            nonce: nonce,
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        let candidate = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://home.local:8443")!,
            householdId: qr.householdId,
            householdName: "Sample Home",
            machineId: "m_mac",
            pairingState: "device",
            shortNonce: qr.shortNonce
        )

        #expect(candidate.matches(qr: qr))
    }

    @Test func candidateRejectsMismatchedHouseholdAndNonce() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x63)
        let qr = PairDeviceQR(
            version: 1,
            householdPublicKey: hhPub,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            nonce: HouseholdTestFixtures.nonce(byte: 0x64),
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        let wrongHousehold = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://other.local:8443")!,
            householdId: "hh_other",
            householdName: "Other",
            machineId: nil,
            pairingState: "device",
            shortNonce: qr.shortNonce
        )
        let wrongNonce = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://home.local:8443")!,
            householdId: qr.householdId,
            householdName: "Sample Home",
            machineId: nil,
            pairingState: "device",
            shortNonce: "different"
        )

        #expect(!wrongHousehold.matches(qr: qr))
        #expect(!wrongNonce.matches(qr: qr))
    }

    /// A Phase 3 publisher (machine join, `pairing=machine`) must never
    /// match a Phase 2 `PairDeviceQR` even when household and nonce
    /// align. The doc-comment on `matches(qr:)` promises this exclusion;
    /// this pin closes the regression vector if a future refactor
    /// loosens the exact-string check (e.g. switches to a permissive
    /// "any non-empty pairing state" guard).
    /// theyos publishes `host` in TXT as a fully-qualified mDNS name
    /// (e.g. `macStudio.local`) because the publisher uses the raw
    /// `gethostname()` output. `endpointURL` MUST detect that case and
    /// not append the search-domain a second time, otherwise the URL
    /// becomes `http://macStudio.local.local:8091` which does not
    /// resolve. Pins the iOS-side regression that surfaced as
    /// `household.pairing.error.noMatchingHousehold` during Story 1
    /// hardware testing on 2026-05-08.
    @Test func endpointURLAcceptsFullyQualifiedHostFromTXT() throws {
        let txt = [
            "hh_id": "hh_eeit7s5ak64oy4cr",
            "host": "macStudio.local",
            "pairing": "device",
            "pair_nonce": "n",
            "proto": "1",
        ]
        let url = HouseholdBonjourBrowser.endpointURL(
            serviceName: "Soyeht-macStudio-local-eeit7s5a",
            domain: "local.",
            txt: txt
        )
        #expect(url == URL(string: "http://macStudio.local:8091"))
    }

    /// Single-label hosts (older publishers, or future single-label
    /// hostnames) MUST still get the search domain appended — the
    /// FQDN detection is by the presence of a dot, not by always
    /// trusting `host` verbatim.
    @Test func endpointURLAppendsDomainForSingleLabelHostFromTXT() throws {
        let txt = [
            "hh_id": "hh_short",
            "host": "home",
            "pairing": "device",
            "pair_nonce": "n",
            "proto": "1",
        ]
        let url = HouseholdBonjourBrowser.endpointURL(
            serviceName: "Soyeht-home-short",
            domain: "local.",
            txt: txt
        )
        #expect(url == URL(string: "http://home.local:8091"))
    }

    /// `txt["url"]` is the explicit-override branch and short-circuits
    /// host construction entirely. Pin so a future refactor of the
    /// fallback path does not drop the override.
    @Test func endpointURLPrefersExplicitURLFromTXT() throws {
        let txt = [
            "hh_id": "hh_x",
            "url": "https://override.example:9443/api",
            "pairing": "device",
            "pair_nonce": "n",
            "proto": "1",
        ]
        let url = HouseholdBonjourBrowser.endpointURL(
            serviceName: "Soyeht-anything",
            domain: "local.",
            txt: txt
        )
        #expect(url == URL(string: "https://override.example:9443/api"))
    }

    @Test func parseDNSSDTXTRecordDecodesLengthPrefixedKeyValues() throws {
        let bytes = Self.dnsSDTXTBytes([
            "hh_id=hh_eeit7s5ak64oy4cr",
            "pairing=device",
            "pair_nonce=KHR86G0i",
            "flag",
            "empty=",
        ])

        let txt = HouseholdBonjourBrowser.parseDNSSDTXTRecord(bytes)

        #expect(txt["hh_id"] == "hh_eeit7s5ak64oy4cr")
        #expect(txt["pairing"] == "device")
        #expect(txt["pair_nonce"] == "KHR86G0i")
        #expect(txt["flag"] == "")
        #expect(txt["empty"] == "")
    }

    @Test func resolvedEndpointDefaultsUseSRVHostAndPortWhenTXTOmitsThem() throws {
        let txt = [
            "hh_id": "hh_eeit7s5ak64oy4cr",
            "pairing": "device",
            "pair_nonce": "n",
            "proto": "1",
        ]

        let merged = HouseholdBonjourBrowser.txtByApplyingResolvedEndpointDefaults(
            txt,
            hostTarget: "macStudio.local.",
            port: 8091
        )
        let url = HouseholdBonjourBrowser.endpointURL(
            serviceName: "Soyeht-macStudio-eeit7s5a",
            domain: "local.",
            txt: merged
        )

        #expect(url == URL(string: "http://macStudio.local:8091"))
    }

    /// `txt["host"]` absent: legacy / non-Mac publishers fall through to
    /// `inferredHostLabel` (strip `Soyeht-` prefix and `-<short>` suffix
    /// from the service name). Pin the inference path so a future
    /// refactor of `inferredHostLabel` does not silently break service
    /// discovery for publishers that don't emit `host` in TXT yet.
    @Test func endpointURLFallsBackToInferredHostLabelWhenTXTHostAbsent() throws {
        let txt = [
            "hh_id": "hh_eeit7s5ak64oy4cr",
            "pairing": "device",
            "pair_nonce": "n",
            "proto": "1",
        ]
        // Service name `Soyeht-home-eeit7s5a` with `hh_id` short
        // `eeit7s5a` (first 8 of base32). inferredHostLabel strips
        // `Soyeht-` prefix and `-eeit7s5a` suffix → `home`. Then domain
        // `.local` is appended via the single-label branch. Final URL
        // host = `home.local`.
        let url = HouseholdBonjourBrowser.endpointURL(
            serviceName: "Soyeht-home-eeit7s5a",
            domain: "local.",
            txt: txt
        )
        #expect(url == URL(string: "http://home.local:8091"))
    }

    /// Cross-repo consistency check: with the exact `hh_pub` that theyos
    /// publishes from the live Story 1 daemon, the iOS-side
    /// `qr.householdId` derivation (BLAKE3 → base32lower 52 chars,
    /// prepended `hh_`) MUST produce the same `hh_id` value that theyos
    /// emits in the Bonjour TXT record. If these diverge, every
    /// `matches(qr:)` will fail at the first conjunct and pairing
    /// silently times out as `noMatchingHousehold`. Story 1 hardware
    /// run 2026-05-08.
    @Test func householdIdMatchesTheyosTXTForLiveStory1HHPub() throws {
        let hhPubB64URL = "A9xYwv62hMUL802ovI1eiLIIRguiw_bkqty3Dtep9SPg"
        let hhPub = try Data(soyehtBase64URL: hhPubB64URL)
        #expect(hhPub.count == 33)
        let computed = try HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let expected = "hh_eeit7s5ak64oy4cr2w4tp6cd2g3lmb7rcgrbh5twwtq7ld3jbdoa"
        #expect(computed == expected)
    }

    @Test func candidateRejectsMachinePairingForDeviceQR() throws {
        let hhPub = HouseholdTestFixtures.publicKey(byte: 0x65)
        let nonce = HouseholdTestFixtures.nonce(byte: 0x66)
        let qr = PairDeviceQR(
            version: 1,
            householdPublicKey: hhPub,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            nonce: nonce,
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        let machineCandidate = HouseholdDiscoveryCandidate(
            endpoint: URL(string: "https://home.local:8443")!,
            householdId: qr.householdId,
            householdName: "Sample Home",
            machineId: "m_mac",
            pairingState: "machine",
            shortNonce: qr.shortNonce
        )

        #expect(!machineCandidate.matches(qr: qr))
    }

    private static func dnsSDTXTBytes(_ entries: [String]) -> [UInt8] {
        entries.flatMap { entry -> [UInt8] in
            let bytes = Array(entry.utf8)
            precondition(bytes.count <= 255)
            return [UInt8(bytes.count)] + bytes
        }
    }
}
