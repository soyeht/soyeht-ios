import XCTest
@testable import SoyehtCore

/// The address a phone dials after a Mac claims it.
///
/// The Mac chooses what to advertise by what the MAC has, and
/// `MacEngineAdvertisedURL` prefers the tailnet address whenever this Mac has
/// one — right for a phone that could use the tailnet, and a dead end for a
/// phone that has no Tailscale at all. MEASURED on the owner's Mac 2026-09-04:
/// it holds a 100.64/10 address, so every claim it sends over the Wi-Fi says
/// "dial me on the tailnet". Opening the LAN on the engine bought nothing while
/// the phone was never told the Wi-Fi address.
final class ClaimEngineAddressChoiceTests: XCTestCase {

    private let tailnet = URL(string: "http://100.64.0.10:8091")!
    private let lan = URL(string: "http://192.168.1.20:8091")!

    func test_takesTheWiFiAddressWhenThePhoneHasNoTailnetOfItsOwn() {
        let choice = ClaimEngineAddressChoice.choose(
            advertised: tailnet, localNetwork: lan, phoneHasTailnetAddress: false
        )
        XCTAssertEqual(choice.url, lan)
        XCTAssertEqual(choice.reason, .localNetworkFallback)
    }

    /// The property this must not cost: a phone on the tailnet keeps the
    /// address that still answers away from home. It stores the endpoint for
    /// the life of the pairing, so handing it the Wi-Fi address here is how
    /// someone silently becomes unreachable the moment they leave the house.
    func test_keepsTheTailnetAddressWhenThePhoneIsOnTheTailnet() {
        let choice = ClaimEngineAddressChoice.choose(
            advertised: tailnet, localNetwork: lan, phoneHasTailnetAddress: true
        )
        XCTAssertEqual(choice.url, tailnet)
        XCTAssertEqual(choice.reason, .tailnetOnBothEnds)
    }

    /// A Mac with no tailnet already advertises something dialable. Nothing to
    /// decide, whatever else is carried.
    func test_leavesANonTailnetAdvertisementAlone() {
        for phoneHasTailnet in [true, false] {
            let choice = ClaimEngineAddressChoice.choose(
                advertised: lan,
                localNetwork: URL(string: "http://192.168.1.99:8091")!,
                phoneHasTailnetAddress: phoneHasTailnet
            )
            XCTAssertEqual(choice.url, lan)
            XCTAssertEqual(choice.reason, .advertised)
        }
    }

    /// A Mac built before this carries no second address. The phone is no
    /// worse off than it was — and the reason says why it is about to fail.
    func test_anOlderMacOffersNothingElseAndTheReasonSaysSo() {
        let choice = ClaimEngineAddressChoice.choose(
            advertised: tailnet, localNetwork: nil, phoneHasTailnetAddress: false
        )
        XCTAssertEqual(choice.url, tailnet)
        XCTAssertEqual(choice.reason, .noReachableAddress)
    }

    /// The second address is not a second chance to be told anything. A
    /// loopback, a tailnet address wearing the LAN field, or a host that is
    /// not an address at all are all refused — the phone would dial its own
    /// machine, or the address it already established it cannot reach.
    func test_refusesASecondAddressThatIsNotALocalNetworkAddress() {
        for impostor in [
            "http://127.0.0.1:8091",
            "http://100.64.9.9:8091",
            "http://mac.example.test:8091",
        ] {
            let choice = ClaimEngineAddressChoice.choose(
                advertised: tailnet,
                localNetwork: URL(string: impostor)!,
                phoneHasTailnetAddress: false
            )
            XCTAssertEqual(choice.url, tailnet, "\(impostor) must not be dialled")
            XCTAssertEqual(choice.reason, .noReachableAddress, "\(impostor)")
        }
    }
}

/// The claim carries the second address across a version gap in both
/// directions: the envelope is plain JSON with no unknown-key rejection.
final class ClaimLocalNetworkAddressWireTests: XCTestCase {

    private func token() throws -> SetupInvitationToken {
        try SetupInvitationToken(bytes: Data(repeating: 7, count: 32))
    }

    func test_theSecondAddressSurvivesAnEncodeAndDecode() throws {
        let claim = SetupInvitationDirectClaim(
            token: try token(),
            macEngineURL: URL(string: "http://100.64.0.10:8091")!,
            macEngineLocalNetworkURL: URL(string: "http://192.168.1.20:8091")!
        )
        let decoded = try SetupInvitationDirectClaim.decode(claim.encodedData())
        XCTAssertEqual(decoded.macEngineLocalNetworkURL, claim.macEngineLocalNetworkURL)
        XCTAssertEqual(decoded.macEngineURL, claim.macEngineURL)
    }

    func test_theKeyOnTheWireIsTheOneBothSidesAgreedOn() throws {
        let claim = SetupInvitationDirectClaim(
            token: try token(),
            macEngineURL: URL(string: "http://100.64.0.10:8091")!,
            macEngineLocalNetworkURL: URL(string: "http://192.168.1.20:8091")!
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claim.encodedData()) as? [String: Any]
        )
        XCTAssertEqual(json["mac_engine_lan_url"] as? String, "http://192.168.1.20:8091")
    }

    /// A Mac built before this sends no such key. It must decode, not throw:
    /// the phone would lose the Mac it was waiting for over a bonus address.
    func test_aClaimFromAnOlderMacStillDecodes() throws {
        let json = """
        {"token":"\(PairingCrypto.base64URLEncode(Data(repeating: 7, count: 32)))",\
        "mac_engine_url":"http://100.64.0.10:8091"}
        """
        let decoded = try SetupInvitationDirectClaim.decode(Data(json.utf8))
        XCTAssertNil(decoded.macEngineLocalNetworkURL)
        XCTAssertEqual(decoded.macEngineURL, URL(string: "http://100.64.0.10:8091"))
    }

    /// And an unreadable one is dropped rather than fatal, for the same
    /// reason.
    func test_anUnreadableSecondAddressDoesNotCostTheClaim() throws {
        let json = """
        {"token":"\(PairingCrypto.base64URLEncode(Data(repeating: 7, count: 32)))",\
        "mac_engine_url":"http://100.64.0.10:8091","mac_engine_lan_url":""}
        """
        let decoded = try SetupInvitationDirectClaim.decode(Data(json.utf8))
        XCTAssertEqual(decoded.macEngineURL, URL(string: "http://100.64.0.10:8091"))
        XCTAssertNil(
            decoded.macEngineLocalNetworkURL.flatMap { $0.host },
            "an address with no host must never be dialled"
        )
    }
}
