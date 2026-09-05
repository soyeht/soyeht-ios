import XCTest
@testable import SoyehtCore

final class BootstrapPairDeviceURIClientTests: XCTestCase {
    func testFetchAttachesEngineListenerFactsToThePairingURI() async throws {
        let hhPub = Data(repeating: 0x02, count: 33)
        let pairURI = "soyeht://household/pair-device?v=1&hh_pub=test&nonce=test&ttl=9999999999"
        let response = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "house_name": .text("HomeStudio"),
            "host_label": .text("Mac Studio"),
            "hh_id": .text("hh_test"),
            "hh_pub": .bytes(hhPub),
            "pair_device_uri": .text(pairURI),
            "expires_at": .unsigned(1_778_600_000),
        ]))
        let client = BootstrapPairDeviceURIClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { request in
                switch request.url?.path {
                case "/bootstrap/pair-device-uri": return (response, makePairDeviceURIHTTPResponse(statusCode: 200))
                case "/bootstrap/pairing-addresses":
                    return (pairingSnapshotFixture(), makePairDeviceURIHTTPResponse(statusCode: 200))
                default: XCTFail("Unexpected route"); throw URLError(.badURL)
                }
            }
        )

        let result = try await client.fetch()

        XCTAssertEqual(result.houseName, "HomeStudio")
        XCTAssertEqual(result.hostLabel, "Mac Studio")
        XCTAssertEqual(result.hhId, "hh_test")
        XCTAssertEqual(result.hhPub, hhPub)
        let uri = try XCTUnwrap(URL(string: result.pairDeviceURI))
        let offer = try XCTUnwrap(PairingLinkAddresses.offer(in: uri))
        XCTAssertEqual(offer.candidates.first?.url.host, "100.64.0.10")
        XCTAssertEqual(offer.generation, "bound-listeners")
        XCTAssertEqual(URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "host" }?.value, "100.64.0.10:8091")
        XCTAssertEqual(result.expiresAt, 1_778_600_000)
    }

    func test_rejectsMalformedPublicKey() async {
        let response = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "house_name": .text("HomeStudio"),
            "host_label": .text("Mac Studio"),
            "hh_id": .text("hh_test"),
            "hh_pub": .bytes(Data(repeating: 0x02, count: 32)),
            "pair_device_uri": .text("soyeht://household/pair-device?v=1"),
        ]))
        let client = BootstrapPairDeviceURIClient(
            baseURL: URL(string: "http://127.0.0.1:8091")!,
            transport: { _ in (response, makePairDeviceURIHTTPResponse(statusCode: 200)) }
        )

        do {
            _ = try await client.fetch()
            XCTFail("expected malformed response to throw")
        } catch BootstrapError.protocolViolation(let detail) {
            XCTAssertEqual(detail, .unexpectedResponseShape)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private func makePairDeviceURIHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:8091/bootstrap/pair-device-uri")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/cbor"]
    )!
}

func pairingSnapshotFixture(candidateOverride: [String: HouseholdCBORValue] = [:]) -> Data {
    var candidate: [String: HouseholdCBORValue] = [
        "url": .text("http://100.64.0.10:8091"), "transport": .text("tailnet"),
        "operations": .array([.text("first_owner")]), "availability": .text("listening"),
        "expires_at_unix": .null,
    ]
    candidate.merge(candidateOverride) { _, replacement in replacement }
    return HouseholdCBOR.encode(.map([
        "v": .unsigned(1), "generation": .text("bound-listeners"),
        "installation": SetupInvitationPayload.installationCBOR(.init(.release)),
        "candidates": .array([.map(candidate)]),
        "authority": .map(["household_id": .text("hh_test"), "owner_person_id": .null, "owner_public_key": .null]),
    ]))
}

final class BootstrapPairingAddressesClientTests: XCTestCase {
    func testSnapshotDecodesAnActualListenerWithoutInferringOwnerFromACount() throws {
        let snapshot = try BootstrapPairingAddressesClient.decode(pairingSnapshotFixture(), expectedInstallation: .init(.release))
        XCTAssertEqual(snapshot.authority.householdID, "hh_test")
        XCTAssertNil(snapshot.authority.ownerPersonID)
        XCTAssertEqual(snapshot.offer.candidates.first?.availability, .listening)
        XCTAssertEqual(snapshot.offer.candidates.first?.operations, [.firstOwner])
    }

    func testSnapshotCannotCrossInstallationProfiles() {
        XCTAssertThrowsError(try BootstrapPairingAddressesClient.decode(pairingSnapshotFixture(), expectedInstallation: .init(.dev))) {
            XCTAssertEqual($0 as? PairingAddressError, .profileMismatch)
        }
    }

    func testWindowGrantCannotMasqueradeAsAListeningEndpoint() {
        XCTAssertThrowsError(try BootstrapPairingAddressesClient.decode(
            pairingSnapshotFixture(candidateOverride: ["availability": .text("advertised")]), expectedInstallation: .init(.release)))
    }

    func testInvalidDeadlineCannotBecomeAnOfferWithoutExpiry() {
        XCTAssertThrowsError(try BootstrapPairingAddressesClient.decode(
            pairingSnapshotFixture(candidateOverride: ["expires_at_unix": .text("later")]), expectedInstallation: .init(.release)))
    }
}
