import XCTest
import CryptoKit
import SoyehtCore
@testable import Soyeht

/// Runs the button's actual view-model path. Discovery has no network side
/// effects here; the local handshake and first-owner enrollment are injected.
@MainActor
final class ExistingHouseConnectionFlowTests: XCTestCase {
    private let token = SetupInvitationToken()
    private let endpoint = URL(string: "http://mac.test:\(EndpointPolicy.defaultBootstrapPort())")!

    private func house(key: Data? = nil, nonce: UInt8 = 1) throws -> SetupInvitationExistingHouse {
        let link = HouseholdDevicePairingLink(
            endpoint: endpoint, householdId: "test-home",
            householdPublicKey: key ?? P256.Signing.PrivateKey().publicKey.compressedRepresentation,
            householdName: "Test Home", pairingNonce: Data(repeating: nonce, count: 32)
        )
        return SetupInvitationExistingHouse(name: "Test Home", hostLabel: "Test Mac",
                                            pairDeviceURI: try link.url().absoluteString)
    }

    private func claim(_ house: SetupInvitationExistingHouse,
                       installation: PairingInstallIdentity? = .current,
                       token: SetupInvitationToken? = nil,
                       endpoint: URL? = nil) -> SetupInvitationDirectClaim {
        SetupInvitationDirectClaim(token: token ?? self.token, macEngineURL: endpoint ?? self.endpoint,
            macLocalPairing: SetupInvitationMacLocalPairing(
                macID: UUID(), macName: "Test Mac", host: "mac.test",
                presencePort: 8001, attachPort: 8002, secret: Data(repeating: 2, count: 32)),
            existingHouse: house, installation: installation)
    }

    private func model(timeout: Duration = .zero,
                       connect: @escaping AwaitingMacViewModel.ConnectLocalMac,
                       enroll: @escaping AwaitingMacViewModel.CreateFirstOwner) -> AwaitingMacViewModel {
        AwaitingMacViewModel(invitation: SetupInvitationPayload(
            token: token, ownerDisplayName: nil,
            expiresAt: UInt64(Date().timeIntervalSince1970) + 3600, iphoneApnsToken: nil),
            connectLocalMac: connect, createFirstOwner: enroll, localClaimTimeout: timeout)
    }

    private func present(_ house: SetupInvitationExistingHouse, claim: SetupInvitationDirectClaim?,
                         on model: AwaitingMacViewModel) throws {
        model.presentExistingHouse(house, engineURL: endpoint,
            deferredLocalPairing: claim?.macLocalPairing, deferredClaim: claim)
        XCTAssertNotNil(model.pendingExistingHouse, "fixture must reach the Connect card")
        XCTAssertEqual(model.fingerprintWords.count, 6)
    }

    func test_discoveryDoesNotInstallAndConnectWaitsForPresenceWithoutEnrolling() async throws {
        let house = try house(), claim = claim(house)
        var connections: [SetupInvitationMacLocalPairing] = []
        var enrollments = 0
        let entered = expectation(description: "presence handshake started")
        var response: CheckedContinuation<Void, Never>?
        let model = model(connect: { pairing in
            connections.append(pairing)
            await withCheckedContinuation { response = $0; entered.fulfill() }
        }, enroll: { _ in enrollments += 1 })
        defer { model.stop() }
        try present(house, claim: claim, on: model)
        XCTAssertTrue(connections.isEmpty)
        XCTAssertEqual(enrollments, 0)
        let task = try XCTUnwrap(model.connectToExistingHouse())
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.isPairing)
        XCTAssertNotEqual(model.phase, .paired(macName: "Test Mac"))
        response?.resume()
        await task.value
        XCTAssertEqual(connections, [try XCTUnwrap(claim.macLocalPairing)])
        XCTAssertEqual(enrollments, 0)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.phase, .paired(macName: "Test Mac"))
    }

    func test_lateClaimAfterConnectUsesTheConfirmedHome() async throws {
        let house = try house(), claim = claim(house)
        var connections = 0, enrollments = 0
        let model = model(timeout: .seconds(2), connect: { _ in connections += 1 },
                          enroll: { _ in enrollments += 1 })
        defer { model.stop() }
        let earlyClaim = SetupInvitationDirectClaim(token: token, macEngineURL: endpoint,
                                                     existingHouse: house)
        try present(house, claim: earlyClaim, on: model)
        let task = try XCTUnwrap(model.connectToExistingHouse())
        await Task.yield()
        XCTAssertTrue(model.isPairing)
        XCTAssertEqual(connections, 0)
        model.acceptLateClaim(claim)
        await task.value
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(enrollments, 0)
        XCTAssertEqual(model.phase, .paired(macName: "Test Mac"))
    }

    func test_missingClaimTimesOutWithoutStartingHouseholdEnrollment() async throws {
        var connections = 0, enrollments = 0
        let model = model(connect: { _ in connections += 1 }, enroll: { _ in enrollments += 1 })
        defer { model.stop() }
        try present(house(), claim: nil, on: model)
        try await XCTUnwrap(model.connectToExistingHouse()).value
        XCTAssertEqual(connections, 0)
        XCTAssertEqual(enrollments, 0)
        guard case .stalled(.pairingFailure(let failure)) = model.phase else {
            return XCTFail("missing claim must be an actionable refusal")
        }
        XCTAssertEqual(failure.stage, .claim)
    }

    func test_wrongHouseProfileOrInvitationNeverInstallsOrEnrolls() async throws {
        let house = try house()
        let invalid = [
            claim(try self.house()),
            claim(house, installation: PairingInstallIdentity(profile: "other", bootstrapPort: 1)),
            claim(house, installation: nil),
            claim(house, token: SetupInvitationToken())
        ]
        for claim in invalid {
            var connections = 0, enrollments = 0
            let model = model(connect: { _ in connections += 1 }, enroll: { _ in enrollments += 1 })
            defer { model.stop() }
            try present(house, claim: claim, on: model)
            try await XCTUnwrap(model.connectToExistingHouse()).value
            XCTAssertEqual(connections, 0)
            XCTAssertEqual(enrollments, 0)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func test_anotherMacInTheSameHomeCannotReplaceTheDisplayedMac() async throws {
        let key = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let house = try house(key: key)
        let otherMac = claim(try self.house(key: key, nonce: 2),
                             endpoint: URL(string: "http://other.test:\(EndpointPolicy.defaultBootstrapPort())")!)
        var connections = 0
        let model = model(connect: { _ in connections += 1 }, enroll: { _ in XCTFail("must not enroll") })
        defer { model.stop() }
        try present(house, claim: nil, on: model)
        model.acceptLateClaim(otherMac)
        XCTAssertNil(model.pendingExistingHouse?.deferredLocalPairing)
        try await XCTUnwrap(model.connectToExistingHouse()).value
        XCTAssertEqual(connections, 0)
    }

    func test_matchingCodeAcceptsAnotherAddressForTheSameMac() async throws {
        let house = try house()
        let claim = claim(house, endpoint: URL(string: "http://mac.local:\(EndpointPolicy.defaultBootstrapPort())")!)
        var connections = 0
        let model = model(connect: { _ in connections += 1 }, enroll: { _ in XCTFail("must not enroll") })
        defer { model.stop() }
        try present(house, claim: nil, on: model)
        model.acceptLateClaim(claim)
        try await XCTUnwrap(model.connectToExistingHouse()).value
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(model.phase, .paired(macName: "Test Mac"))
    }

    func test_presenceFailureNeverReportsConnectedOrStartsEnrollment() async throws {
        let house = try house()
        let model = model(connect: { _ in throw URLError(.cannotConnectToHost) },
                          enroll: { _ in XCTFail("must not enroll") })
        defer { model.stop() }
        try present(house, claim: claim(house), on: model)
        try await XCTUnwrap(model.connectToExistingHouse()).value
        XCTAssertNotEqual(model.phase, .paired(macName: "Test Mac"))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isPairing)
    }

    func test_cancellationDoesNotInstallAPendingClaim() async throws {
        let house = try house()
        var connections = 0
        let model = model(timeout: .seconds(2), connect: { _ in connections += 1 },
                          enroll: { _ in XCTFail("must not enroll") })
        try present(house, claim: nil, on: model)
        let task = try XCTUnwrap(model.connectToExistingHouse())
        await Task.yield()
        model.stop()
        await task.value
        XCTAssertEqual(connections, 0)
        XCTAssertNotEqual(model.phase, .paired(macName: "Test Mac"))
    }
    func test_ownedHomeClaimWithoutEngineRouteStillOffersMacConnectionAfterConfirmation() async throws {
        let house = try house()
        let engine = URL(string: "http://100.64.0.1:\(EndpointPolicy.defaultBootstrapPort())")!
        let offered = claim(house)
        let claim = SetupInvitationDirectClaim(
            token: token, macEngineURL: engine,
            macLocalPairing: offered.macLocalPairing, existingHouse: house,
            installation: .current, event: .existingHouseOffered,
            addressOffer: PairingAddressPolicy.legacyOffer(endpoints: [engine], installation: .current)
        )
        let phone = PhoneNetworkEvidence(hasTailnetAddress: false)
        XCTAssertThrowsError(try claim.chooseAddress(phone: phone)) {
            XCTAssertEqual($0 as? PairingAddressError, .noReachableAddress)
        }
        var connections: [SetupInvitationMacLocalPairing] = []
        var enrollments = 0
        let model = model(connect: { connections.append($0) }, enroll: { _ in enrollments += 1 })
        defer { model.stop() }

        // Start at discovery. Calling presentExistingHouse here would skip the
        // engine-address guard that rejected the physical VPN-off run.
        await model.handleDirectClaim(claim, phone: phone)
        XCTAssertNotNil(model.pendingExistingHouse)
        XCTAssertEqual(model.fingerprintWords.count, 6)
        XCTAssertTrue(connections.isEmpty, "discovery must not install the secret")
        XCTAssertEqual(enrollments, 0)
        try await XCTUnwrap(model.connectToExistingHouse()).value
        XCTAssertEqual(connections, [try XCTUnwrap(claim.macLocalPairing)])
        XCTAssertEqual(enrollments, 0)
        XCTAssertEqual(model.phase, .paired(macName: "Test Mac"))
    }

    func test_discoveryRefusesOtherInvitationProfileAndUntypedClaims() async throws {
        let house = try house()
        let pairing = try XCTUnwrap(claim(house).macLocalPairing)
        let engine = URL(string: "http://100.64.0.1:\(EndpointPolicy.defaultBootstrapPort())")!
        let otherPort = EndpointPolicy.defaultBootstrapPort() == 8101 ? 8091 : 8101
        let variants: [(SetupInvitationToken, PairingInstallIdentity?, SetupInvitationDirectClaim.Event?, URL)] = [
            (SetupInvitationToken(), .current, .existingHouseOffered, engine),
            (token, nil, .existingHouseOffered, engine),
            (token, PairingInstallIdentity(profile: "other", bootstrapPort: otherPort), .existingHouseOffered, engine),
            (token, .current, .existingHouseOffered, URL(string: "http://100.64.0.1:\(otherPort)")!),
            (token, .current, nil, engine),
            (token, .current, .bootstrapClaimAccepted, engine)
        ]
        for (invitation, installation, event, endpoint) in variants {
            let model = model(connect: { _ in XCTFail("invalid claim cannot connect") },
                              enroll: { _ in XCTFail("invalid claim cannot enroll") })
            defer { model.stop() }
            let claim = SetupInvitationDirectClaim(token: invitation, macEngineURL: endpoint,
                macLocalPairing: pairing, existingHouse: house, installation: installation,
                event: event, addressOffer: PairingAddressPolicy.legacyOffer(endpoints: [engine], installation: .current))
            await model.handleDirectClaim(claim, phone: .init(hasTailnetAddress: false))
            XCTAssertNil(model.pendingExistingHouse)
            XCTAssertNil(model.connectToExistingHouse())
        }
    }

    func test_firstOwnerStillRequiresAnEligibleEngineRouteEvenWithLocalCredential() async throws {
        let engine = URL(string: "http://100.64.0.1:\(EndpointPolicy.defaultBootstrapPort())")!
        var qr = URLComponents(string: "soyeht://household/pair-device")!
        qr.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "hh_pub", value: P256.Signing.PrivateKey().publicKey.compressedRepresentation.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: Data(repeating: 3, count: 32).soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(Int(Date().timeIntervalSince1970) + 600)),
            URLQueryItem(name: "m_cert_fp", value: Data(repeating: 4, count: 32).soyehtBase64URLEncodedString()),
            URLQueryItem(name: "crit", value: "m_cert_fp")
        ]
        let qrURL = try XCTUnwrap(qr.url)
        XCTAssertNoThrow(try PairDeviceQR(url: qrURL), "fixture must be a valid first-owner link")
        let first = SetupInvitationExistingHouse(name: "New Home", hostLabel: "Test Mac",
                                                 pairDeviceURI: qrURL.absoluteString)
        let model = model(connect: { _ in XCTFail("first owner must not skip enrollment") },
                          enroll: { _ in XCTFail("no engine route was available") })
        defer { model.stop() }
        let incoming = SetupInvitationDirectClaim(token: token, macEngineURL: engine,
            macLocalPairing: claim(first).macLocalPairing, existingHouse: first,
            installation: .current, event: .existingHouseOffered,
            addressOffer: PairingAddressPolicy.legacyOffer(endpoints: [engine], installation: .current))
        await model.handleDirectClaim(incoming, phone: .init(hasTailnetAddress: false))
        XCTAssertNil(model.pendingExistingHouse)
        guard case .stalled(.pairingFailure(let failure)) = model.phase else {
            return XCTFail("first-owner HTTP route refusal must remain explicit")
        }
        XCTAssertEqual(failure.cause, .address(.noReachableAddress))
    }

    func test_lateLocalClaimCanReachTheConfirmedCardWithoutAnEngineRoute() async throws {
        let house = try house()
        let engine = URL(string: "http://100.64.0.1:\(EndpointPolicy.defaultBootstrapPort())")!
        let local = try XCTUnwrap(claim(house).macLocalPairing)
        var connections = 0
        let model = model(timeout: .seconds(2), connect: { _ in connections += 1 },
                          enroll: { _ in XCTFail("must not enroll") })
        defer { model.stop() }
        let initialEngine = URL(string: "http://192.168.1.10:\(EndpointPolicy.defaultBootstrapPort())")!
        let first = SetupInvitationDirectClaim(token: token, macEngineURL: initialEngine,
            existingHouse: house, installation: .current, event: .existingHouseOffered,
            addressOffer: PairingAddressPolicy.legacyOffer(endpoints: [initialEngine], installation: .current))
        XCTAssertNoThrow(try first.chooseAddress(phone: .init(hasTailnetAddress: false)),
                         "the early card fixture must have an eligible engine route")
        await model.handleDirectClaim(first, phone: .init(hasTailnetAddress: false))
        let task = try XCTUnwrap(model.connectToExistingHouse())
        await Task.yield()
        XCTAssertEqual(connections, 0)
        let late = SetupInvitationDirectClaim(token: token, macEngineURL: engine,
            macLocalPairing: local, existingHouse: house, installation: .current, event: .existingHouseOffered,
            addressOffer: PairingAddressPolicy.legacyOffer(endpoints: [engine], installation: .current))
        await model.handleDirectClaim(late, phone: .init(hasTailnetAddress: false))
        await task.value
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(model.phase, .paired(macName: "Test Mac"))
    }

}
