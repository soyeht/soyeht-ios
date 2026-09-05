import XCTest
@testable import SoyehtCore

final class PairingAddressPolicyTests: XCTestCase {
    private let installation = PairingInstallIdentity(profile: "dev", bootstrapPort: 8101)
    private let tailnet = URL(string: "http://100.64.0.10:8101")!
    private let lan = URL(string: "http://192.168.1.20:8101")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ url: URL, operations: Set<PairingOperation> = [.firstOwner],
                           expires: Date? = nil) -> PairingAddressCandidate {
        PairingAddressCandidate(url: url,
                                transport: PairingAddressPolicy.transport(of: url) ?? .localNetwork,
                                operations: operations, availability: .listening, expiresAt: expires)
    }

    private func offer(_ candidates: [PairingAddressCandidate]) -> PairingAddressOffer {
        PairingAddressOffer(installation: installation, generation: "engine-1/binds-2", candidates: candidates)
    }

    private func choose(_ offer: PairingAddressOffer, tailnet: Bool?, reached: Set<URL> = []) throws -> PairingAddressDecision {
        try PairingAddressPolicy.choose(offer: offer, expectedInstallation: installation,
                                        phone: PhoneNetworkEvidence(hasTailnetAddress: tailnet, reachedEndpoints: reached),
                                        operation: .firstOwner, now: now)
    }

    func test_keepsTheTailnetAddressWhenThePhoneIsOnTheTailnet() throws {
        let decision = try choose(offer([candidate(lan), candidate(tailnet)]), tailnet: true, reached: [lan])
        XCTAssertEqual(decision.url, tailnet)
        XCTAssertEqual(decision.reason, .tailnetOnBothEnds)
    }

    func test_pureWiFiCanPairEvenWhenTheMacAlsoHasTailnet() throws {
        let decision = try choose(offer([candidate(tailnet), candidate(lan)]), tailnet: false)
        XCTAssertEqual(decision.url, lan)
        XCTAssertEqual(decision.reason, .localNetworkFallback)
    }

    func test_unreachableTailnetDoesNotReturnAFakeSuccessfulChoice() {
        XCTAssertThrowsError(try choose(offer([candidate(tailnet)]), tailnet: false)) {
            XCTAssertEqual($0 as? PairingAddressError, .noReachableAddress)
        }
    }

    func test_aBoundAddressDoesNotGrantAnOperation() {
        XCTAssertThrowsError(try choose(offer([candidate(lan, operations: [.addDevice])]), tailnet: false)) {
            XCTAssertEqual($0 as? PairingAddressError, .operationUnavailable)
        }
    }

    func test_anExpiredLANWindowCannotBeUsedBecauseItWasReachedEarlier() {
        XCTAssertThrowsError(try choose(offer([candidate(lan, expires: now)]), tailnet: false, reached: [lan])) {
            XCTAssertEqual($0 as? PairingAddressError, .expiredOffer)
        }
    }

    func test_noBindHasNoCandidate() {
        XCTAssertThrowsError(try choose(offer([]), tailnet: false)) {
            XCTAssertEqual($0 as? PairingAddressError, .noAvailableEndpoint)
        }
    }

    func test_installationIsValidatedBeforeCandidates() {
        let wrong = PairingAddressOffer(installation: .init(profile: "release", bootstrapPort: 8091),
                                        generation: "x", candidates: [candidate(lan)])
        XCTAssertThrowsError(try choose(wrong, tailnet: false)) {
            XCTAssertEqual($0 as? PairingAddressError, .profileMismatch)
        }
    }

    func test_loopbackWrongServiceAndSecretsAreNeverDialled() throws {
        for raw in ["http://127.0.0.1:8101", "http://localhost:8101", "http://[::1]:8101",
                    "http://192.168.1.20:8091", "http://192.168.1.20:8902",
                    "http://user:password@192.168.1.20:8101", "http://192.168.1.20:8101?token=secret",
                    "http://192.168.1.20:8101/bootstrap/status", "http://0.0.0.0:8101"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try choose(offer([candidate(url)]), tailnet: false), raw) {
                XCTAssertEqual($0 as? PairingAddressError, .invalidEndpoint, raw)
            }
        }
    }

    func test_anInvalidAlternateDoesNotPoisonAValidTailnetCandidate() throws {
        let wrong = candidate(URL(string: "http://192.168.1.20:8091")!)
        XCTAssertEqual(try choose(offer([wrong, candidate(tailnet)]), tailnet: true).url, tailnet)
    }

    func test_oldDecisionCannotCrossAnEngineOrBindingGeneration() throws {
        let original = offer([candidate(tailnet)])
        let decision = try choose(original, tailnet: true)
        let replacement = PairingAddressOffer(installation: installation, generation: "engine-2/binds-2",
                                             candidates: original.candidates)
        XCTAssertThrowsError(try PairingAddressPolicy.validate(decision, against: replacement, now: now)) {
            XCTAssertEqual($0 as? PairingAddressError, .staleDecision)
        }
    }

    func test_tailnetIPv6AndDNSUseTheSameClassificationAsEndpointPolicy() throws {
        for raw in ["http://[fd7a:115c:a1e0::1]:8101", "http://mac.example.ts.net:8101"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(PairingAddressPolicy.transport(of: url), .tailnet)
            XCTAssertEqual(try choose(offer([candidate(lan), candidate(url)]), tailnet: true, reached: [lan]).url, url)
        }
    }
}
