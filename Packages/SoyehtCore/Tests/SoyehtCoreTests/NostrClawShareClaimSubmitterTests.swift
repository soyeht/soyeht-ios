import CryptoKit
import Foundation
import P256K
import XCTest

@testable import SoyehtCore

final class NostrClawShareClaimSubmitterTests: XCTestCase {
    func testSubmitterPublishesRelayStreamOnlyClaimAndReturnsVerifiedRelayOffer() async throws {
        let relay = MockNostrRelay()
        let slowRelay = MockNostrRelay()
        let relayURL = URL(string: "wss://relay.example.test/")!
        let slowRelayURL = URL(string: "wss://relay-slow.example.test/")!
        let relayCloses = AsyncCounter()
        let slowRelayConnections = AsyncCounter()
        let slowRelayCloses = AsyncCounter()
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let guestProvider = FixedGuestIdentityProvider(
            identity: try EphemeralClawShareGuestIdentity(rawRepresentation: Data(repeating: 0x33, count: 32))
        )
        let engineKey = try Self.engineKey()
        let unsignedInvite = ClawShareInvite(
            householdId: "hh_alpha",
            ownerPersonId: "p_alpha",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw_alpha",
            slotId: Data(repeating: 0x22, count: 16),
            transportHint: .loopback(channel: "ch-alpha"),
            expiresAt: 1_800_000_600,
            ownerEngineNpub: engineKey.xonlyHex,
            claimRelays: [relayURL.absoluteString, slowRelayURL.absoluteString],
            ownerSignature: Data(repeating: 0, count: 64)
        )
        let invite = try Self.signedInvite(unsignedInvite, ownerKey: ownerKey)
        let random = LockedRandomBytes([
            Data(repeating: 0x44, count: 32), // claim nonce
            Data(repeating: 0x77, count: 32), // friend Nostr scalar
            Data(repeating: 0x88, count: 32), // claim encryption nonce
        ])
        let submitter = NostrClawShareClaimSubmitter(
            ackTimeout: 5,
            transportFactory: { url in
                if url == slowRelayURL {
                    await slowRelayConnections.increment()
                    return TrackingNostrTransport(
                        base: await slowRelay.accept(),
                        closeCounter: slowRelayCloses
                    )
                }
                return TrackingNostrTransport(
                    base: await relay.accept(),
                    closeCounter: relayCloses
                )
            },
            randomBytes: { count in try random.next(count: count) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let engineTransport = await relay.accept()
        let engineClient = NostrWSSClient(transport: engineTransport, ackTimeout: 5)
        try await engineClient.connect()
        let stream = try await engineClient.subscribe(
            id: "engine-claims",
            filter: ["kinds": [1059], "#p": [engineKey.xonlyHex]]
        )
        let capturedClaim = CapturedClaim()
        let engineTask = Task {
            for await event in stream where event.kind == 1059 {
                let friendPub = try XCTUnwrap(Self.compressedPubForNostrEvent(event))
                let claimCBOR = try Self.decryptHexPayload(
                    event.content,
                    privateKey: engineKey.privateKey,
                    peerPublicKey: friendPub
                )
                let claim = try ClawShareCodec.decodeClaim(claimCBOR)
                await capturedClaim.set(claim)
                try await Self.waitForCount(slowRelayConnections, atLeast: 1)
                let credential = try Self.signedCredential(
                    invite: invite,
                    guestPublicKey: claim.guestDevicePublicKey,
                    ownerKey: ownerKey
                )
                let offer = try Self.signedOffer(
                    credential: credential,
                    ownerKey: ownerKey,
                    relayEndpoint: "relay-stream://198.51.100.10:49152"
                )
                let ack = ClawShareAck(
                    credential: credential,
                    tunnel: .loopback(channel: "ch-alpha"),
                    relayStreamOfferBytes: offer.canonicalBytes()
                )
                let ackCiphertext = try NostrNIP44.encrypt(
                    plaintext: Data(ClawShareCodec.encode(ack).soyehtHexEncodedString().utf8),
                    myPrivKey: engineKey.privateKey,
                    peerPubKey: friendPub,
                    nonce: Data(repeating: 0x99, count: 32)
                )
                let ackEvent = try NostrEventSigning.sign(
                    privateKey: engineKey.privateKey,
                    pubkey: engineKey.xonlyHex,
                    createdAt: 1_800_000_001,
                    kind: 1059,
                    tags: [["p", event.pubkey]],
                    content: ackCiphertext
                )
                try await engineClient.publish(ackEvent)
                return
            }
        }

        let session = try await submitter.submit(invite: invite, identityProvider: guestProvider)
        try await engineTask.value
        await engineClient.close()
        await relay.shutdown()
        await slowRelay.shutdown()

        let captured = await capturedClaim.value()
        let claim = try XCTUnwrap(captured)
        XCTAssertNil(claim.participantNpub)
        XCTAssertEqual(claim.guestDevicePublicKey, session.guestPublicKeyData)
        XCTAssertEqual(session.relayStreamOffer?.payload.expectedPath, .relayStream)
        XCTAssertEqual(session.relayStreamOffer?.payload.relayEndpoint, "relay-stream://198.51.100.10:49152")
        let relayCloseCount = await relayCloses.value()
        let slowRelayCloseCount = await slowRelayCloses.value()
        XCTAssertGreaterThan(relayCloseCount, 0)
        XCTAssertGreaterThan(slowRelayCloseCount, 0)
    }

    func testSubmitterRejectsAckRelayOfferWithMismatchedSlot() async throws {
        let relay = MockNostrRelay()
        let relayURL = URL(string: "wss://relay.example.test/")!
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let guestProvider = FixedGuestIdentityProvider(
            identity: try EphemeralClawShareGuestIdentity(rawRepresentation: Data(repeating: 0x33, count: 32))
        )
        let engineKey = try Self.engineKey()
        let unsignedInvite = ClawShareInvite(
            householdId: "hh_alpha",
            ownerPersonId: "p_alpha",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw_alpha",
            slotId: Data(repeating: 0x22, count: 16),
            transportHint: .loopback(channel: "ch-alpha"),
            expiresAt: 1_800_000_600,
            ownerEngineNpub: engineKey.xonlyHex,
            claimRelays: [relayURL.absoluteString],
            ownerSignature: Data(repeating: 0, count: 64)
        )
        let invite = try Self.signedInvite(unsignedInvite, ownerKey: ownerKey)
        let random = LockedRandomBytes([
            Data(repeating: 0x44, count: 32), // claim nonce
            Data(repeating: 0x77, count: 32), // friend Nostr scalar
            Data(repeating: 0x88, count: 32), // claim encryption nonce
        ])
        let submitter = NostrClawShareClaimSubmitter(
            ackTimeout: 5,
            transportFactory: { _ in await relay.accept() },
            randomBytes: { count in try random.next(count: count) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let engineTransport = await relay.accept()
        let engineClient = NostrWSSClient(transport: engineTransport, ackTimeout: 5)
        try await engineClient.connect()
        let stream = try await engineClient.subscribe(
            id: "engine-claims",
            filter: ["kinds": [1059], "#p": [engineKey.xonlyHex]]
        )
        let engineTask = Task {
            for await event in stream where event.kind == 1059 {
                let friendPub = try XCTUnwrap(Self.compressedPubForNostrEvent(event))
                let claimCBOR = try Self.decryptHexPayload(
                    event.content,
                    privateKey: engineKey.privateKey,
                    peerPublicKey: friendPub
                )
                let claim = try ClawShareCodec.decodeClaim(claimCBOR)
                let credential = try Self.signedCredential(
                    invite: invite,
                    guestPublicKey: claim.guestDevicePublicKey,
                    ownerKey: ownerKey
                )
                let offer = try Self.signedOffer(
                    credential: credential,
                    ownerKey: ownerKey,
                    relayEndpoint: "relay-stream://198.51.100.10:49152",
                    slotId: Data(repeating: 0x23, count: 16)
                )
                let ack = ClawShareAck(
                    credential: credential,
                    tunnel: .loopback(channel: "ch-alpha"),
                    relayStreamOfferBytes: offer.canonicalBytes()
                )
                let ackCiphertext = try NostrNIP44.encrypt(
                    plaintext: Data(ClawShareCodec.encode(ack).soyehtHexEncodedString().utf8),
                    myPrivKey: engineKey.privateKey,
                    peerPubKey: friendPub,
                    nonce: Data(repeating: 0x99, count: 32)
                )
                let ackEvent = try NostrEventSigning.sign(
                    privateKey: engineKey.privateKey,
                    pubkey: engineKey.xonlyHex,
                    createdAt: 1_800_000_001,
                    kind: 1059,
                    tags: [["p", event.pubkey]],
                    content: ackCiphertext
                )
                try await engineClient.publish(ackEvent)
                return
            }
        }

        do {
            _ = try await submitter.submit(invite: invite, identityProvider: guestProvider)
            XCTFail("Expected relay offer mismatch to be rejected")
        } catch {
            XCTAssertEqual(error as? ClawShareError, .relayStreamOfferRejected)
        }
        try await engineTask.value
        await engineClient.close()
        await relay.shutdown()
    }

    private static func engineKey() throws -> (privateKey: Data, xonlyHex: String) {
        for seed in UInt8(1)...UInt8(250) {
            let scalar = Data(repeating: seed, count: 32)
            guard let privateKey = try? P256K.KeyAgreement.PrivateKey(dataRepresentation: scalar) else {
                continue
            }
            let publicKey = privateKey.publicKey.dataRepresentation
            if publicKey.first == 0x02, publicKey.count == 33 {
                return (scalar, publicKey.subdata(in: 1..<33).soyehtHexEncodedString())
            }
        }
        throw ClawShareError.inviteMalformed
    }

    private static func compressedPubForNostrEvent(_ event: NostrEvent) throws -> Data {
        guard let xonly = Data(soyehtHex: event.pubkey), xonly.count == 32 else {
            throw ClawShareError.unexpectedFrame
        }
        var compressed = Data([0x02])
        compressed.append(xonly)
        return compressed
    }

    private static func decryptHexPayload(
        _ payload: String,
        privateKey: Data,
        peerPublicKey: Data
    ) throws -> Data {
        let plaintext = try NostrNIP44.decrypt(
            payloadBase64: payload,
            myPrivKey: privateKey,
            peerPubKey: peerPublicKey
        )
        let hex = try XCTUnwrap(String(data: plaintext, encoding: .utf8))
        return try XCTUnwrap(Data(soyehtHex: hex))
    }

    private static func signedCredential(
        invite: ClawShareInvite,
        guestPublicKey: Data,
        ownerKey: P256.Signing.PrivateKey
    ) throws -> GuestCredential {
        let unsigned = GuestCredential(
            householdId: invite.householdId,
            ownerPersonId: invite.ownerPersonId,
            ownerPublicKey: invite.ownerPublicKey,
            clawId: invite.clawId,
            guestDevicePublicKey: guestPublicKey,
            slotId: invite.slotId,
            issuedAt: 1_800_000_000,
            expiresAt: 1_800_000_600,
            ownerSignature: Data(repeating: 0, count: 64)
        )
        let signature = try ownerKey.signature(
            for: ClawShareCodec.canonicalCredentialSigningBytes(unsigned)
        ).rawRepresentation
        return GuestCredential(
            householdId: unsigned.householdId,
            ownerPersonId: unsigned.ownerPersonId,
            ownerPublicKey: unsigned.ownerPublicKey,
            clawId: unsigned.clawId,
            guestDevicePublicKey: unsigned.guestDevicePublicKey,
            slotId: unsigned.slotId,
            issuedAt: unsigned.issuedAt,
            expiresAt: unsigned.expiresAt,
            ownerSignature: signature
        )
    }

    private static func signedInvite(
        _ invite: ClawShareInvite,
        ownerKey: P256.Signing.PrivateKey
    ) throws -> ClawShareInvite {
        let signature = try ownerKey.signature(
            for: ClawShareCodec.canonicalInviteSigningBytes(invite)
        ).rawRepresentation
        return ClawShareInvite(
            householdId: invite.householdId,
            ownerPersonId: invite.ownerPersonId,
            ownerPublicKey: invite.ownerPublicKey,
            clawId: invite.clawId,
            slotId: invite.slotId,
            transportHint: invite.transportHint,
            expiresAt: invite.expiresAt,
            ownerEngineNpub: invite.ownerEngineNpub,
            claimRelays: invite.claimRelays,
            ownerSignature: signature
        )
    }

    private static func signedOffer(
        credential: GuestCredential,
        ownerKey: P256.Signing.PrivateKey,
        relayEndpoint: String,
        clawId: String? = nil,
        slotId: Data? = nil,
        resource: RelayStreamResource = .pty,
        notAfter: UInt64? = nil
    ) throws -> RelayStreamOfferContract {
        let payload = RelayStreamOfferPayload(
            rendezvousToken: Data(repeating: 0x42, count: 16),
            clawId: clawId ?? credential.clawId,
            slotId: slotId ?? credential.slotId,
            guestDevicePublicKey: credential.guestDevicePublicKey,
            resource: resource,
            expectedPath: .relayStream,
            relayEndpoint: relayEndpoint,
            clawStaticPublicKey: Data(repeating: 0x33, count: 32),
            notAfter: notAfter ?? credential.expiresAt
        )
        let signature = try ownerKey.signature(for: payload.canonicalBytes()).rawRepresentation
        return RelayStreamOfferContract(
            payload: payload,
            signerPublicKey: ownerKey.publicKey.compressedRepresentation,
            signature: signature
        )
    }

    private static func waitForCount(
        _ counter: AsyncCounter,
        atLeast expected: Int,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await counter.value() >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ClawShareError.transportClosed
    }
}

private struct TrackingNostrTransport: NostrWireTransport {
    let base: any NostrWireTransport
    let closeCounter: AsyncCounter

    func send(_ frame: String) async throws {
        try await base.send(frame)
    }

    func recv() async throws -> String? {
        try await base.recv()
    }

    func close() async {
        await closeCounter.increment()
        await base.close()
    }
}

private actor AsyncCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct FixedGuestIdentityProvider: ClawShareGuestIdentityProvider {
    let identity: EphemeralClawShareGuestIdentity

    func create() throws -> any ClawShareGuestIdentity {
        identity
    }
}

private final class LockedRandomBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(_ values: [Data]) {
        self.values = values
    }

    func next(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { throw ClawShareError.transportClosed }
        let value = values.removeFirst()
        guard value.count == count else { throw ClawShareError.transportClosed }
        return value
    }
}

private actor CapturedClaim {
    private var claim: ClawShareClaim?

    func set(_ claim: ClawShareClaim) {
        self.claim = claim
    }

    func value() -> ClawShareClaim? {
        claim
    }
}

private actor MockNostrRelay {
    private final class Connection {
        let transport: InProcessWSSTransport
        var subscriptions: [String: [String: Any]] = [:]

        init(transport: InProcessWSSTransport) {
            self.transport = transport
        }
    }

    private var connections: [Connection] = []
    private var events: [NostrEvent] = []
    private var serverTasks: [Task<Void, Never>] = []

    func accept() async -> any NostrWireTransport {
        let pair = await InProcessWSSTransport.makePair()
        let connection = Connection(transport: pair.server)
        connections.append(connection)
        serverTasks.append(Task { [weak self] in
            await self?.run(connection: connection)
        })
        return pair.client
    }

    func shutdown() async {
        for task in serverTasks {
            task.cancel()
        }
        for connection in connections {
            await connection.transport.close()
        }
        connections.removeAll()
        events.removeAll()
        serverTasks.removeAll()
    }

    private func run(connection: Connection) async {
        while !Task.isCancelled {
            guard let frame = try? await connection.transport.recv() else { return }
            await handle(frame: frame, connection: connection)
        }
    }

    private func handle(frame: String, connection: Connection) async {
        guard let data = frame.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [Any],
              let kind = array.first as? String
        else {
            return
        }

        switch kind {
        case "REQ":
            guard array.count >= 3,
                  let subId = array[1] as? String,
                  let filter = array[2] as? [String: Any]
            else {
                return
            }
            connection.subscriptions[subId] = filter
            for event in events where Self.event(event, matches: filter) {
                if let frame = try? Self.encode(["EVENT", subId, event.toJSON()]) {
                    try? await connection.transport.send(frame)
                }
            }
        case "EVENT":
            guard array.count >= 2,
                  let eventJSON = array[1] as? [String: Any],
                  let event = NostrEvent.fromJSON(eventJSON)
            else {
                return
            }
            events.append(event)
            if let ok = try? Self.encode(["OK", event.id, true, ""]) {
                try? await connection.transport.send(ok)
            }
            for connection in connections {
                for (subId, filter) in connection.subscriptions where Self.event(event, matches: filter) {
                    if let eventFrame = try? Self.encode(["EVENT", subId, event.toJSON()]) {
                        try? await connection.transport.send(eventFrame)
                    }
                }
            }
        default:
            break
        }
    }

    private static func encode(_ value: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func event(_ event: NostrEvent, matches filter: [String: Any]) -> Bool {
        if let kinds = filter["kinds"] as? [Int], !kinds.contains(Int(event.kind)) {
            return false
        }
        if let pTags = filter["#p"] as? [String] {
            let eventTags = event.tags.compactMap { tag -> String? in
                guard tag.count >= 2, tag[0] == "p" else { return nil }
                return tag[1]
            }
            if !eventTags.contains(where: pTags.contains) {
                return false
            }
        }
        if let since = filter["since"] as? Int, event.createdAt < UInt64(since) {
            return false
        }
        return true
    }
}
