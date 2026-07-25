import CryptoKit
import Foundation
import RelayStreamGuestFFI
@_spi(ClawStoreE2E) import SoyehtCore
import XCTest

@testable import Soyeht

final class RelayStreamIPTunnelControllerTests: XCTestCase {
    func testEphemeralStartOptionsRejectExpiredAndGuestMismatchedMaterial() throws {
        let nowUnix: UInt64 = 1_900_000_000
        let guestPublicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let request = RelayStreamAuthSigningRequest(
            authMode: .offerPayload,
            signingBytes: Data([1, 2, 3]),
            sessionId: "session-alpha",
            endpoint: "relay-stream://192.0.2.10:443",
            targetId: "claw-alpha",
            expiresAt: nowUnix + 60,
            nonce: Data(repeating: 0x44, count: 16),
            authMaterialCbor: Data([0xA1, 0x01]),
            guestDevicePub: guestPublicKey
        )
        let options = try RelayStreamGuestTunnelStartOptions(
            offerCbor: Data([0xA1, 0x02]),
            expectedOwnerPub: P256.Signing.PrivateKey().publicKey.compressedRepresentation,
            expectedGuestPub: guestPublicKey,
            request: request,
            signature: Data(repeating: 0x55, count: 64),
            issuedAtUnix: nowUnix,
            connectTimeoutMs: 10_000
        )
        let encoded = try options.encode()

        XCTAssertThrowsError(try RelayStreamGuestTunnelStartOptions.decode(
            encoded,
            nowUnix: request.expiresAt
        )) { error in
            XCTAssertEqual(
                error as? RelayStreamGuestTunnelStartOptionsError,
                .expired
            )
        }

        XCTAssertThrowsError(try RelayStreamGuestTunnelStartOptions(
            offerCbor: Data([0xA1, 0x02]),
            expectedOwnerPub: P256.Signing.PrivateKey().publicKey.compressedRepresentation,
            expectedGuestPub: P256.Signing.PrivateKey().publicKey.compressedRepresentation,
            request: request,
            signature: Data(repeating: 0x55, count: 64),
            issuedAtUnix: nowUnix,
            connectTimeoutMs: 10_000
        )) { error in
            XCTAssertEqual(
                error as? RelayStreamGuestTunnelStartOptionsError,
                .malformed
            )
        }
    }

    func testActivateSignsInHostPersistsOnlyStaticConfigAndStartsWithEphemeralOptions() async throws {
        SoyehtFeatureFlags.setRelayStreamIPTunnelActivationEnabledOverride(true)
        defer { SoyehtFeatureFlags.setRelayStreamIPTunnelActivationEnabledOverride(nil) }

        let nowUnix: UInt64 = 1_900_000_000
        let ownerKey = P256.Signing.PrivateKey()
        let guestIdentity = EphemeralClawShareGuestIdentity()
        let offer = try makeOffer(
            ownerKey: ownerKey,
            guestPublicKey: guestIdentity.publicKeyData,
            nowUnix: nowUnix
        )
        let request = RelayStreamAuthSigningRequest(
            authMode: .offerPayload,
            signingBytes: Data("signed-request".utf8),
            sessionId: "ios-ip-tunnel-session-alpha",
            endpoint: offer.payload.relayEndpoint,
            targetId: offer.payload.clawId,
            expiresAt: nowUnix + 60,
            nonce: Data(repeating: 0x44, count: 32),
            authMaterialCbor: offer.payload.canonicalBytes(),
            guestDevicePub: guestIdentity.publicKeyData
        )
        let native = RecordingRelayStreamNativeAPI(request: request)
        let unrelated = RecordingRelayStreamTunnelManager(
            providerBundleIdentifier: "com.example.unrelated"
        )
        let matching = RecordingRelayStreamTunnelManager(
            providerBundleIdentifier: "com.example.dev.SoyehtClawShareTunnelProvider"
        )
        let loader = RecordingRelayStreamTunnelManagerLoader(
            installed: [unrelated, matching]
        )
        let controller = RelayStreamIPTunnelController(
            managers: loader,
            client: RelayStreamGuestDataPlaneClient(native: native),
            providerBundleIdentifier: "com.example.dev.SoyehtClawShareTunnelProvider",
            now: { Date(timeIntervalSince1970: TimeInterval(nowUnix)) },
            uuid: { UUID(uuidString: "00000000-0000-4000-8000-000000000001")! }
        )
        let claimed = ClaimedGroupRelayStreamOffer(
            relayStreamOffer: offer,
            guestIdentity: guestIdentity,
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            groupId: "group-alpha",
            memberId: "member-alpha",
            clawId: "claw-alpha"
        )

        try await controller.activate(claimed: claimed)

        XCTAssertEqual(loader.makeCount, 0)
        XCTAssertEqual(unrelated.saveCount, 0)
        XCTAssertEqual(matching.saveCount, 1)
        XCTAssertEqual(matching.reloadCount, 1)
        XCTAssertEqual(
            matching.configuredProviderBundleIdentifier,
            "com.example.dev.SoyehtClawShareTunnelProvider"
        )
        XCTAssertEqual(matching.staticProviderConfiguration["schema"] as? String, "relay-stream-ip-tunnel-v1")
        XCTAssertEqual(matching.staticProviderConfiguration["start_options"] as? String, "ephemeral-only")
        XCTAssertFalse(matching.staticProviderConfiguration.values.contains { $0 is Data || $0 is NSData })

        let encoded = try XCTUnwrap(matching.startedOptions)
        let decoded = try RelayStreamGuestTunnelStartOptions.decode(
            encoded,
            nowUnix: nowUnix
        )
        XCTAssertEqual(decoded.offerCbor, offer.canonicalBytes())
        XCTAssertEqual(decoded.expectedOwnerPub, ownerKey.publicKey.compressedRepresentation)
        XCTAssertEqual(decoded.expectedGuestPub, guestIdentity.publicKeyData)
        XCTAssertEqual(decoded.authMode, .offerPayload)
        XCTAssertEqual(decoded.signingBytes, request.signingBytes)
        XCTAssertEqual(decoded.authMaterialCbor, offer.payload.canonicalBytes())
        XCTAssertEqual(decoded.endpoint, offer.payload.relayEndpoint)
        XCTAssertEqual(decoded.targetId, offer.payload.clawId)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decoded.signature)
        XCTAssertTrue(
            try P256.Signing.PublicKey(
                compressedRepresentation: guestIdentity.publicKeyData
            ).isValidSignature(signature, for: request.signingBytes)
        )
        XCTAssertEqual(native.preparedInputs.count, 1)
        XCTAssertNil(native.preparedInputs[0].credentialCbor)
    }

    func testActivateRejectsClaimedGroupMismatchBeforePreferencesMutation() async throws {
        SoyehtFeatureFlags.setRelayStreamIPTunnelActivationEnabledOverride(true)
        defer { SoyehtFeatureFlags.setRelayStreamIPTunnelActivationEnabledOverride(nil) }

        let nowUnix: UInt64 = 1_900_000_000
        let ownerKey = P256.Signing.PrivateKey()
        let guestIdentity = EphemeralClawShareGuestIdentity()
        let offer = try makeOffer(
            ownerKey: ownerKey,
            guestPublicKey: guestIdentity.publicKeyData,
            nowUnix: nowUnix
        )
        let native = RecordingRelayStreamNativeAPI(
            request: RelayStreamAuthSigningRequest(
                authMode: .offerPayload,
                signingBytes: Data([1]),
                sessionId: "session-alpha",
                endpoint: offer.payload.relayEndpoint,
                targetId: offer.payload.clawId,
                expiresAt: nowUnix + 60,
                nonce: Data(repeating: 1, count: 16),
                authMaterialCbor: offer.payload.canonicalBytes(),
                guestDevicePub: guestIdentity.publicKeyData
            )
        )
        let loader = RecordingRelayStreamTunnelManagerLoader(installed: [])
        let controller = RelayStreamIPTunnelController(
            managers: loader,
            client: RelayStreamGuestDataPlaneClient(native: native),
            providerBundleIdentifier: "com.example.dev.SoyehtClawShareTunnelProvider",
            now: { Date(timeIntervalSince1970: TimeInterval(nowUnix)) }
        )
        let claimed = ClaimedGroupRelayStreamOffer(
            relayStreamOffer: offer,
            guestIdentity: guestIdentity,
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            groupId: "group-other",
            memberId: "member-alpha",
            clawId: "claw-alpha"
        )

        do {
            try await controller.activate(claimed: claimed)
            XCTFail("expected group mismatch")
        } catch {
            XCTAssertEqual(
                error as? RelayStreamIPTunnelController.ActivationError,
                .groupMismatch
            )
        }
        XCTAssertEqual(loader.loadCount, 0)
        XCTAssertEqual(loader.makeCount, 0)
        XCTAssertTrue(native.preparedInputs.isEmpty)
    }

    func testActivateFailsClosedBeforeOfferSigningOrPreferencesWhenGateDisabled() async throws {
        SoyehtFeatureFlags.setRelayStreamIPTunnelActivationEnabledOverride(false)
        defer { SoyehtFeatureFlags.setRelayStreamIPTunnelActivationEnabledOverride(nil) }

        let nowUnix: UInt64 = 1_900_000_000
        let ownerKey = P256.Signing.PrivateKey()
        let guestIdentity = EphemeralClawShareGuestIdentity()
        let offer = try makeOffer(
            ownerKey: ownerKey,
            guestPublicKey: guestIdentity.publicKeyData,
            nowUnix: nowUnix
        )
        let native = RecordingRelayStreamNativeAPI(
            request: RelayStreamAuthSigningRequest(
                authMode: .offerPayload,
                signingBytes: Data([1]),
                sessionId: "session-alpha",
                endpoint: offer.payload.relayEndpoint,
                targetId: offer.payload.clawId,
                expiresAt: nowUnix + 60,
                nonce: Data(repeating: 1, count: 16),
                authMaterialCbor: offer.payload.canonicalBytes(),
                guestDevicePub: guestIdentity.publicKeyData
            )
        )
        let loader = RecordingRelayStreamTunnelManagerLoader(installed: [])
        let controller = RelayStreamIPTunnelController(
            managers: loader,
            client: RelayStreamGuestDataPlaneClient(native: native),
            providerBundleIdentifier: "com.example.dev.SoyehtClawShareTunnelProvider",
            now: { Date(timeIntervalSince1970: TimeInterval(nowUnix)) }
        )
        let claimed = ClaimedGroupRelayStreamOffer(
            relayStreamOffer: offer,
            guestIdentity: guestIdentity,
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            groupId: "group-alpha",
            memberId: "member-alpha",
            clawId: "claw-alpha"
        )

        do {
            try await controller.activate(claimed: claimed)
            XCTFail("expected activation gate to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RelayStreamIPTunnelController.ActivationError,
                .activationDisabled
            )
        }
        XCTAssertEqual(loader.loadCount, 0)
        XCTAssertEqual(loader.makeCount, 0)
        XCTAssertTrue(native.preparedInputs.isEmpty)
    }

    private func makeOffer(
        ownerKey: P256.Signing.PrivateKey,
        guestPublicKey: Data,
        nowUnix: UInt64
    ) throws -> RelayStreamOfferContract {
        let payload = RelayStreamOfferPayload(
            rendezvousToken: Data(repeating: 0x11, count: 32),
            clawId: "claw-alpha",
            slotId: Data(repeating: 0x33, count: 16),
            guestDevicePublicKey: guestPublicKey,
            resource: .ipTunnel,
            expectedPath: .relayStream,
            relayEndpoint: "relay-stream://192.0.2.10:443",
            clawStaticPublicKey: Data(repeating: 0x55, count: 32),
            notAfter: nowUnix + 120,
            authz: .group(groupId: "group-alpha", memberId: "member-alpha")
        )
        let signature = try ownerKey.signature(for: payload.canonicalBytes())
        return RelayStreamOfferContract(
            payload: payload,
            signerPublicKey: ownerKey.publicKey.compressedRepresentation,
            signature: signature.rawRepresentation
        )
    }
}

private final class RecordingRelayStreamNativeAPI: RelayStreamGuestNativeAPI, @unchecked Sendable {
    let request: RelayStreamAuthSigningRequest
    private(set) var preparedInputs: [RelayStreamPrepareAuthInput] = []

    init(request: RelayStreamAuthSigningRequest) {
        self.request = request
    }

    func prepareAuthSigningRequest(
        input: RelayStreamPrepareAuthInput
    ) throws -> RelayStreamAuthSigningRequest {
        preparedInputs.append(input)
        return request
    }

    func connect(
        offerCbor _: Data,
        expectedOwnerPub _: Data,
        expectedGuestPub _: Data,
        request _: RelayStreamAuthSigningRequest,
        signature _: Data,
        nowUnix _: UInt64,
        connectTimeoutMs _: UInt64
    ) async throws -> any RelayStreamGuestSessionProtocol {
        throw RecordingRelayStreamTunnelError.unexpectedConnect
    }
}

private final class RecordingRelayStreamTunnelManager: RelayStreamTunnelManager, @unchecked Sendable {
    private(set) var providerBundleIdentifier: String?
    private(set) var configuredProviderBundleIdentifier: String?
    private(set) var staticProviderConfiguration: [String: Any] = [:]
    private(set) var saveCount = 0
    private(set) var reloadCount = 0
    private(set) var startedOptions: Data?

    init(providerBundleIdentifier: String?) {
        self.providerBundleIdentifier = providerBundleIdentifier
    }

    func configure(
        providerBundleIdentifier: String,
        localizedDescription _: String,
        staticProviderConfiguration: [String: Any]
    ) {
        configuredProviderBundleIdentifier = providerBundleIdentifier
        self.providerBundleIdentifier = providerBundleIdentifier
        self.staticProviderConfiguration = staticProviderConfiguration
    }

    func save() async throws {
        saveCount += 1
    }

    func reload() async throws {
        reloadCount += 1
    }

    func start(ephemeralOptions: Data) throws {
        startedOptions = ephemeralOptions
    }
}

private final class RecordingRelayStreamTunnelManagerLoader: RelayStreamTunnelManagerLoading, @unchecked Sendable {
    private let installed: [any RelayStreamTunnelManager]
    private let created = RecordingRelayStreamTunnelManager(providerBundleIdentifier: nil)
    private(set) var loadCount = 0
    private(set) var makeCount = 0

    init(installed: [any RelayStreamTunnelManager]) {
        self.installed = installed
    }

    func loadAll() async throws -> [any RelayStreamTunnelManager] {
        loadCount += 1
        return installed
    }

    func makeManager() -> any RelayStreamTunnelManager {
        makeCount += 1
        return created
    }
}

private enum RecordingRelayStreamTunnelError: Error {
    case unexpectedConnect
}
