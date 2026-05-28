import Foundation
import XCTest
import CryptoKit
import P256K

@testable import SoyehtCore

/// End-to-end proof for the friend-side claim ceremony.
///
/// Exercises the SAME production submitter
/// (`NostrClawShareClaimSubmitter`) and the SAME center wiring
/// (`ClawShareInviteRouter`, identity, codec, NIP-44 v2) the iOS
/// app ships — the only thing swapped is the byte transport: an
/// in-process `MockNostrRelay` replaces URLSessionWebSocketTask so
/// the test runs hermetically without a public relay.
///
/// Covered scenarios:
/// 1. Multi-relay fanout: invite carries two relays, the first is
///    dead. Submitter still succeeds via the live relay.
/// 2. "Engine offline at tap": claim is published, stored on the
///    relay, engine subscribes later, drains the stored claim,
///    publishes ack, submitter receives.
/// 3. Persistent outbox: after a kill-mid-publish the outbox
///    record survives and a fresh submitter can re-run the
///    submission, claim again propagates, engine processes once
///    (slot dedupe is the engine's job — both attempts produce
///    the same `slot_id`).
/// 4. HTTP path is never reached (HTTPClawShareClaimSubmitter is
///    not constructed anywhere on the production code path used
///    by the test).
final class NostrClawShareE2ETests: XCTestCase {
    /// Mint an engine secp256k1 keypair whose compressed pubkey
    /// begins with 0x02 (even y). Required because the invite
    /// carries the engine's x-only pubkey and the submitter
    /// reconstructs the compressed point with the 0x02 prefix —
    /// odd-y engine keys would land on the wrong curve point for
    /// ECDH.
    private func mintEvenYEngineKey() throws -> (priv: Data, xonly: String, compressedPub: Data) {
        for _ in 0..<100 {
            let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            do {
                let priv = try P256K.KeyAgreement.PrivateKey(dataRepresentation: secret)
                let pub = priv.publicKey.dataRepresentation
                if pub.first == 0x02 && pub.count == 33 {
                    let xonly = pub.subdata(in: 1..<33).hexHere()
                    return (secret, xonly, pub)
                }
            } catch {
                continue
            }
        }
        XCTFail("could not mint even-y engine key")
        throw ClawShareError.inviteMalformed
    }

    func testMultiRelayFanoutEngineOfflineThenAcks() async throws {
        // ─── relays ───────────────────────────────────────────────────────
        let aliveRelay = MockNostrRelay()
        // The "dead" relay is modelled by a factory that throws when
        // the URL host matches.
        let aliveURL = URL(string: "wss://alive.test/")!
        let deadURL = URL(string: "wss://dead.test/")!

        let factory: NostrClawShareClaimSubmitter.TransportFactory = { @Sendable url in
            if url.host == "alive.test" {
                return await aliveRelay.accept()
            }
            throw ClawShareError.transportClosed
        }

        // ─── engine key + invite ──────────────────────────────────────────
        let engineKey = try mintEvenYEngineKey()
        let ownerScalar = Data(repeating: 0x11, count: 32)
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: ownerScalar)
        let invite = ClawShareInvite(
            householdId: "hh_e2e_test",
            ownerPersonId: "p_e2e_test",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw_e2e_v1",
            slotId: Data(repeating: 0xAB, count: 16),
            transportHint: .loopback(channel: "ch-e2e"),
            expiresAt: UInt64(Date().timeIntervalSince1970) + 3600,
            ownerEngineNpub: "npub_\(engineKey.xonly)",
            claimRelays: [deadURL.absoluteString, aliveURL.absoluteString],
            ownerSignature: Data(repeating: 0xEE, count: 64)
        )

        // ─── outbox in a temp dir so the test is hermetic ────────────────
        let outboxDir = try makeTempDir()
        let outbox = ClawShareClaimOutbox(directory: outboxDir)
        let submitter = NostrClawShareClaimSubmitter(
            outbox: outbox,
            connectTimeout: 5,
            ackTimeout: 10,
            transportFactory: factory
        )

        // ─── engine task: subscribe + ack first matching claim ────────────
        let engineTransport = await aliveRelay.accept()
        let engineClient = NostrWSSClient(transport: engineTransport, ackTimeout: 5)
        try await engineClient.connect()

        // Engine simulates "offline at tap": it subscribes ~150 ms
        // AFTER the submission begins. The mock relay stores the
        // claim and replays it on subscribe — same behaviour a real
        // NIP-01 relay exposes.
        let engineXonlyHex = engineKey.xonly
        let engineCompressedPub = engineKey.compressedPub
        let engineNostrPriv = engineKey.priv
        let engineTask: Task<Void, Error> = Task {
            try await Task.sleep(nanoseconds: 150_000_000)
            let stream = try await engineClient.subscribe(
                id: "engine-claims",
                filter: [
                    "kinds": [1059],
                    "#p": [engineXonlyHex],
                ]
            )
            for await event in stream {
                guard event.kind == 1059 else { continue }
                // Decrypt friend's claim.
                let friendXonly = event.pubkey
                guard let friendXonlyData = Data(hexHere: friendXonly) else {
                    continue
                }
                var friendCompressed = Data([0x02])
                friendCompressed.append(friendXonlyData)
                var claimCBOR: Data?
                do {
                    claimCBOR = try NostrNIP44.decrypt(
                        payloadBase64: event.content,
                        myPrivKey: engineNostrPriv,
                        peerPubKey: friendCompressed
                    )
                } catch {
                    var alt = Data([0x03])
                    alt.append(friendXonlyData)
                    do {
                        claimCBOR = try NostrNIP44.decrypt(
                            payloadBase64: event.content,
                            myPrivKey: engineNostrPriv,
                            peerPubKey: alt
                        )
                    } catch {
                        continue
                    }
                }
                guard let claimCBOR else { continue }

                // Build a GuestCredential bound to the invite.
                let credential = GuestCredential(
                    v: 1,
                    kind: GuestCredential.kind,
                    householdId: invite.householdId,
                    ownerPersonId: invite.ownerPersonId,
                    ownerPublicKey: invite.ownerPublicKey,
                    clawId: invite.clawId,
                    guestDevicePublicKey: Data(repeating: 0xCC, count: 33),
                    slotId: invite.slotId,
                    issuedAt: UInt64(Date().timeIntervalSince1970),
                    expiresAt: UInt64(Date().timeIntervalSince1970) + 86_400,
                    ownerSignature: Data(repeating: 0xEE, count: 64)
                )
                // ack carries the bound credential — the submitter
                // verifies the binding via assertBoundTo. The
                // guestDevicePublicKey here is the test's fixed
                // [0xCC; 33] so the submitter's binding assertion
                // would FAIL if we let it through unmodified. We
                // patch it to the friend's actual guest pubkey by
                // decoding it from the claim.
                let claimPub = Self.guestDevicePubFromClaimCBOR(claimCBOR)
                    ?? Data(repeating: 0xCC, count: 33)
                let boundCred = GuestCredential(
                    v: credential.v,
                    kind: credential.kind,
                    householdId: credential.householdId,
                    ownerPersonId: credential.ownerPersonId,
                    ownerPublicKey: credential.ownerPublicKey,
                    clawId: credential.clawId,
                    guestDevicePublicKey: claimPub,
                    slotId: credential.slotId,
                    issuedAt: credential.issuedAt,
                    expiresAt: credential.expiresAt,
                    ownerSignature: credential.ownerSignature
                )
                let ack = ClawShareAck(
                    v: 1,
                    credential: boundCred,
                    tunnel: .loopback(channel: "ch-e2e")
                )
                let ackPlain = ClawShareCodec.encode(ack)
                let nip44Nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                let ackCipher = try NostrNIP44.encrypt(
                    plaintext: ackPlain,
                    myPrivKey: engineNostrPriv,
                    peerPubKey: friendCompressed,
                    nonce: nip44Nonce
                )
                let ackEvent = try NostrEventSigning.sign(
                    privateKey: engineNostrPriv,
                    pubkey: engineXonlyHex,
                    createdAt: UInt64(Date().timeIntervalSince1970),
                    kind: 1059,
                    tags: [["p", event.pubkey]],
                    content: ackCipher
                )
                try await engineClient.publish(ackEvent)
                return
            }
        }

        let identity = EphemeralClawShareGuestIdentityProvider()
        let session = try await submitter.submit(
            invite: invite,
            identityProvider: identity
        )
        // Engine task must complete cleanly.
        try await engineTask.value
        await engineClient.close()
        await aliveRelay.shutdown()

        // ─── assertions ───────────────────────────────────────────────────
        XCTAssertEqual(session.credential.clawId, invite.clawId)
        XCTAssertEqual(session.credential.slotId, invite.slotId)
        // Outbox cleared on success.
        let pending = try await outbox.pending()
        XCTAssertTrue(pending.isEmpty, "outbox must be empty after success")
    }

    /// Persistent outbox survives a kill before ack and a fresh
    /// submitter can re-run the submission. The relay stores
    /// duplicate publishes idempotently (Nostr event id is
    /// content-derived; same payload + same nonce → same id).
    func testOutboxRecordSurvivesKillBeforeAck() async throws {
        let aliveRelay = MockNostrRelay()
        let aliveURL = URL(string: "wss://alive.test/")!
        let factory: NostrClawShareClaimSubmitter.TransportFactory = { @Sendable url in
            if url.host == "alive.test" {
                return await aliveRelay.accept()
            }
            throw ClawShareError.transportClosed
        }
        let engineKey = try mintEvenYEngineKey()
        let ownerScalar = Data(repeating: 0x22, count: 32)
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: ownerScalar)
        let invite = ClawShareInvite(
            householdId: "hh_kill_test",
            ownerPersonId: "p_kill_test",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw_kill_v1",
            slotId: Data(repeating: 0x33, count: 16),
            transportHint: .loopback(channel: "ch-kill"),
            expiresAt: UInt64(Date().timeIntervalSince1970) + 3600,
            ownerEngineNpub: "npub_\(engineKey.xonly)",
            claimRelays: [aliveURL.absoluteString],
            ownerSignature: Data(repeating: 0xEE, count: 64)
        )
        let outboxDir = try makeTempDir()
        let outbox = ClawShareClaimOutbox(directory: outboxDir)

        // ─── First submitter: short ack timeout so it gives up before
        //     the engine has a chance to reply. The outbox record
        //     MUST survive this failure.
        let killedSubmitter = NostrClawShareClaimSubmitter(
            outbox: outbox,
            connectTimeout: 1,
            ackTimeout: 1,
            transportFactory: factory
        )
        let identity = EphemeralClawShareGuestIdentityProvider()
        do {
            _ = try await killedSubmitter.submit(invite: invite, identityProvider: identity)
            XCTFail("first attempt must time out because engine never connects")
        } catch {
            // expected — outbox should still hold the record.
        }
        let afterKill = try await outbox.pending()
        XCTAssertEqual(
            afterKill.count, 1,
            "outbox must keep the pending claim after a kill-before-ack"
        )
        XCTAssertEqual(afterKill[0].slotIdHex, invite.slotId.hexHere())

        // ─── "Relaunch": fresh submitter sees the outbox, but the
        //     production behaviour is to re-issue submission from the
        //     invite + identity (the outbox is the durable proof that
        //     we tried). Drive a second submit; this time the engine
        //     is online from the start.
        let engineTransport = await aliveRelay.accept()
        let engineClient = NostrWSSClient(transport: engineTransport, ackTimeout: 5)
        try await engineClient.connect()
        let engineXonlyHex = engineKey.xonly
        let engineNostrPriv = engineKey.priv
        let stream = try await engineClient.subscribe(
            id: "engine-relaunch",
            filter: ["kinds": [1059], "#p": [engineXonlyHex]]
        )
        // Long-running engine: processes EVERY inbound 1059 event.
        // The relaunch scenario needs this because the engine sees
        // both the killed submitter's claim (which it acks but no
        // one receives, since the killed connection is gone) and
        // the relaunched submitter's fresh claim (which IS what we
        // need to assert succeeds).
        let engineTask: Task<Void, Error> = Task {
            for await event in stream {
                guard event.kind == 1059 else { continue }
                guard let friendXonlyData = Data(hexHere: event.pubkey) else { continue }
                var compressed = Data([0x02])
                compressed.append(friendXonlyData)
                var claimCBOR: Data?
                claimCBOR = try? NostrNIP44.decrypt(
                    payloadBase64: event.content,
                    myPrivKey: engineNostrPriv,
                    peerPubKey: compressed
                )
                if claimCBOR == nil {
                    compressed = Data([0x03]); compressed.append(friendXonlyData)
                    claimCBOR = try? NostrNIP44.decrypt(
                        payloadBase64: event.content,
                        myPrivKey: engineNostrPriv,
                        peerPubKey: compressed
                    )
                }
                guard let claimCBOR else { continue }
                let claimPub = Self.guestDevicePubFromClaimCBOR(claimCBOR)
                    ?? Data(repeating: 0xCC, count: 33)
                let cred = GuestCredential(
                    v: 1, kind: GuestCredential.kind,
                    householdId: invite.householdId,
                    ownerPersonId: invite.ownerPersonId,
                    ownerPublicKey: invite.ownerPublicKey,
                    clawId: invite.clawId,
                    guestDevicePublicKey: claimPub,
                    slotId: invite.slotId,
                    issuedAt: UInt64(Date().timeIntervalSince1970),
                    expiresAt: UInt64(Date().timeIntervalSince1970) + 86_400,
                    ownerSignature: Data(repeating: 0xEE, count: 64)
                )
                let ack = ClawShareAck(v: 1, credential: cred, tunnel: .loopback(channel: "ch-kill"))
                let cipher = try NostrNIP44.encrypt(
                    plaintext: ClawShareCodec.encode(ack),
                    myPrivKey: engineNostrPriv,
                    peerPubKey: compressed,
                    nonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                )
                let ackEvent = try NostrEventSigning.sign(
                    privateKey: engineNostrPriv,
                    pubkey: engineXonlyHex,
                    createdAt: UInt64(Date().timeIntervalSince1970),
                    kind: 1059,
                    tags: [["p", event.pubkey]],
                    content: cipher
                )
                try await engineClient.publish(ackEvent)
                // loop — engine stays online for the next claim
            }
        }

        let relaunched = NostrClawShareClaimSubmitter(
            outbox: outbox,
            connectTimeout: 5,
            ackTimeout: 10,
            transportFactory: factory
        )
        let session = try await relaunched.submit(invite: invite, identityProvider: identity)
        engineTask.cancel()
        await engineClient.close()
        await aliveRelay.shutdown()

        XCTAssertEqual(session.credential.slotId, invite.slotId)
        let afterSuccess = try await outbox.pending()
        XCTAssertTrue(afterSuccess.isEmpty, "outbox must be empty after the relaunch succeeds")
    }

    // MARK: - helpers

    private static func guestDevicePubFromClaimCBOR(_ data: Data) -> Data? {
        // Decode the claim envelope just enough to lift the guest pub.
        guard let value = try? HouseholdCBOR.decode(data),
              case .map(let m) = value,
              let bytes = m["guest_device_pub"],
              case .bytes(let b) = bytes
        else { return nil }
        return b
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claw-share-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Hex helpers (test-only, named to avoid clashes)

private extension Data {
    func hexHere() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
    init?(hexHere hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        var idx = hex.startIndex
        for _ in 0..<(hex.count / 2) {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = Data(out)
    }
}
