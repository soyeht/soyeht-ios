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
}
