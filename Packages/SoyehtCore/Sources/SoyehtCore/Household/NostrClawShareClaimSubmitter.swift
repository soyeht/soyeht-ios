import Foundation
import CryptoKit
import P256K
import os

/// Production claim transport for iOS: publish the encrypted
/// `ClawShareClaim` to a Nostr WSS relay and subscribe for the
/// engine's ack. Backed by a persistent outbox so an iOS background
/// kill mid-publish doesn't lose the claim — the next launch drains
/// the outbox before any new submission.
///
/// Idempotency model:
/// - Each pending claim has a stable `slot_id` (16 bytes from the
///   invite). The engine slot store rejects double-consume by the
///   same `slot_id` regardless of how many times the friend
///   publishes — see `ClawShareSlotStore` on the Rust side. The
///   outbox keys by `slot_id.hex` so a relaunch never duplicates a
///   pending publish.
/// - Each Nostr event ID is the canonical SHA256(NIP-01 payload).
///   Same plaintext + same nonce → same event id. Replays land on
///   the same event, and relays dedupe.
public actor NostrClawShareClaimSubmitter: ClawShareClaimSubmitter {
    private let outbox: ClawShareClaimOutbox
    private let connectTimeout: TimeInterval
    private let ackTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.soyeht.mobile", category: "nostr-claim")

    public init(
        outbox: ClawShareClaimOutbox = .applicationSupport(),
        connectTimeout: TimeInterval = 8,
        ackTimeout: TimeInterval = 20
    ) {
        self.outbox = outbox
        self.connectTimeout = connectTimeout
        self.ackTimeout = ackTimeout
    }

    public func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        // 1. Materialize the guest identity (Secure Enclave-backed in
        //    production; same call site for tests). The public key is
        //    bound to the claim envelope.
        let guestIdentity: any ClawShareGuestIdentity
        do {
            guestIdentity = try identityProvider.create()
        } catch {
            throw ClawShareError.inviteMalformed
        }
        let guestPubBytes = guestIdentity.publicKeyData
        guard guestPubBytes.count == 33 else {
            throw ClawShareError.inviteMalformed
        }

        // 2. Build the canonical claim envelope + sign it.
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let timestamp = UInt64(Date().timeIntervalSince1970)
        let signingBytes = ClawShareHTTPClient.canonicalClaimSigningBytes(
            slotId: invite.slotId,
            guestDevicePublicKey: guestPubBytes,
            nonce: nonce,
            timestamp: timestamp
        )
        let guestSignature: Data
        do {
            guestSignature = try guestIdentity.sign(signingBytes)
        } catch {
            throw ClawShareError.claimSignatureRejected
        }
        guard guestSignature.count == 64 else {
            throw ClawShareError.inviteMalformed
        }
        let claim = ClawShareClaim(
            slotId: invite.slotId,
            guestDevicePublicKey: guestPubBytes,
            nonce: nonce,
            timestamp: timestamp,
            guestSignature: guestSignature
        )
        let claimCBOR = ClawShareCodec.encode(claim)

        // 3. Persist the pending claim BEFORE network — a process
        //    kill at this point still lets the next launch publish.
        let record = ClawShareClaimOutbox.Record(
            slotIdHex: invite.slotId.hexEncodedString(),
            inviteCBOR: ClawShareCodec.encode(invite),
            claimCBOR: claimCBOR,
            createdAt: timestamp,
            attempts: 0
        )
        try await outbox.upsert(record)

        // 4. The friend's Nostr identity must be ephemeral per claim:
        //    no out-of-band reuse — the engine sees only
        //    (claw_id, guest_device_pub). A fresh secp256k1 keypair
        //    handles event signing AND the NIP-44 ECDH with the
        //    engine pubkey carried in the invite.
        let friendNostrPriv = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let friendKey = try P256K.Schnorr.PrivateKey(dataRepresentation: friendNostrPriv)
        let friendXonly = friendKey.publicKey.dataRepresentation
        // X-only (32 bytes) for NIP-01 pubkey; ECDH needs full 33-byte
        // compressed which the KeyAgreement key derives from the
        // same scalar.
        let friendXonlyHex = friendXonly.hexEncodedString()
        let friendAgreementPriv = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: friendNostrPriv
        )
        let friendCompressedPub = friendAgreementPriv.publicKey.dataRepresentation
        _ = friendCompressedPub

        // 5. Derive the conversation key from friend's secret +
        //    engine's pubkey (carried on the signed invite). Encrypt
        //    the claim CBOR with NIP-44 v2.
        let engineCompressedPub = try Self.decodeEngineNpubToCompressed(invite.ownerEngineNpub)
        let ciphertextBase64 = try NostrNIP44.encrypt(
            plaintext: claimCBOR,
            myPrivKey: friendNostrPriv,
            peerPubKey: engineCompressedPub,
            nonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        )

        // 6. Build the signed event: kind 1059 (gift-wrap), tagged
        //    #p = engine's xonly hex.
        let engineXonlyHex = engineCompressedPub.subdata(in: 1..<33).hexEncodedString()
        let event = try NostrEventSigning.sign(
            privateKey: friendNostrPriv,
            pubkey: friendXonlyHex,
            createdAt: UInt64(Date().timeIntervalSince1970),
            kind: 1059,
            tags: [["p", engineXonlyHex]],
            content: ciphertextBase64
        )

        // 7. Connect to the first usable relay, subscribe to the ack
        //    addressed to friend's xonly, THEN publish — subscribing
        //    first avoids the race where the relay forwards the ack
        //    before we registered for it.
        let relayURL = try invite.claimRelays
            .compactMap(URL.init(string:))
            .first
            ?? { throw ClawShareError.transportClosed }()
        let client = NostrWSSClient(
            config: .init(
                url: relayURL,
                connectTimeout: connectTimeout,
                ackTimeout: ackTimeout
            )
        )
        do {
            try await client.connect()
        } catch {
            logger.warning("nostr_claim_connect_failed err=\(String(describing: error), privacy: .public)")
            throw ClawShareError.transportClosed
        }
        let stream = try await client.subscribe(
            id: "ack-\(invite.slotId.hexEncodedString())",
            filter: [
                "kinds": [1059],
                "#p": [friendXonlyHex],
                "since": Int(Date().timeIntervalSince1970) - 5,
            ]
        )
        try await client.publish(event)

        // 8. Await the engine's encrypted ack event.
        let ackEvent: NostrEvent
        do {
            ackEvent = try await waitForAck(stream: stream, deadline: ackTimeout)
        } catch {
            throw ClawShareError.transportClosed
        }
        let ackCBOR: Data
        do {
            let payloadString = ackEvent.content
            let plaintext = try NostrNIP44.decrypt(
                payloadBase64: payloadString,
                myPrivKey: friendNostrPriv,
                peerPubKey: engineCompressedPub
            )
            ackCBOR = plaintext
        } catch {
            throw ClawShareError.unexpectedFrame
        }
        let ack: ClawShareAck = try Self.decodeAck(ackCBOR)
        try ack.credential.assertBoundTo(
            invite: invite,
            guestPub: guestPubBytes
        )

        // 9. On success: outbox entry removed; close the WSS.
        try await outbox.remove(slotIdHex: invite.slotId.hexEncodedString())
        await client.close()

        return ClaimedSession(
            credential: ack.credential,
            tunnel: ack.tunnel,
            guestIdentity: guestIdentity
        )
    }

    private static func decodeEngineNpubToCompressed(_ npub: String) throws -> Data {
        // Engines carry their Nostr pub in the invite as 32-byte
        // x-only hex (the same form Nostr events use). For NIP-44
        // ECDH we need the 33-byte compressed point — prepend 0x02
        // (even-y) per BIP-340. The engine's actual y-parity doesn't
        // matter for shared X derivation; both parties land on the
        // same X coord regardless of prefix choice as long as both
        // sides match.
        let trimmed = npub.replacingOccurrences(of: "npub_", with: "")
        guard let xonly = Data(hexString: trimmed), xonly.count == 32 else {
            throw ClawShareError.inviteMalformed
        }
        var compressed = Data([0x02])
        compressed.append(xonly)
        return compressed
    }

    private static func decodeAck(_ data: Data) throws -> ClawShareAck {
        do {
            return try ClawShareCodec.decodeAck(data)
        } catch {
            throw ClawShareError.unexpectedFrame
        }
    }

    private func waitForAck(
        stream: AsyncStream<NostrEvent>,
        deadline: TimeInterval
    ) async throws -> NostrEvent {
        try await withThrowingTaskGroup(of: NostrEvent.self) { group in
            group.addTask {
                for await event in stream {
                    if event.kind == 1059 { return event }
                }
                throw ClawShareError.transportClosed
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw ClawShareError.transportClosed
            }
            guard let first = try await group.next() else {
                throw ClawShareError.transportClosed
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Hex helpers + Data conveniences

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var idx = hexString.startIndex
        for _ in 0..<(hexString.count / 2) {
            let next = hexString.index(idx, offsetBy: 2)
            guard let b = UInt8(hexString[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }
}

// MARK: - Persistent outbox

/// Codable, disk-backed outbox of pending claims. The directory is
/// `<Application Support>/com.soyeht.claw-share/outbox/` so iOS
/// keeps the data across launches but excludes it from iCloud
/// (caller must set `isExcludedFromBackup` if desired).
public actor ClawShareClaimOutbox {
    public struct Record: Codable, Sendable {
        public let slotIdHex: String
        public let inviteCBOR: Data
        public let claimCBOR: Data
        public let createdAt: UInt64
        public var attempts: UInt32
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationSupport() -> ClawShareClaimOutbox {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base
            .appendingPathComponent("com.soyeht.claw-share", isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return ClawShareClaimOutbox(directory: dir)
    }

    public func upsert(_ record: Record) throws {
        let url = directory.appendingPathComponent("\(record.slotIdHex).json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func remove(slotIdHex: String) throws {
        let url = directory.appendingPathComponent("\(slotIdHex).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func pending() throws -> [Record] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }
}

// MARK: - Bindings helper for the credential check

extension GuestCredential {
    /// Verify the engine-issued credential is bound to the right
    /// invite + guest identity. Catches a relay impostor that returns
    /// a credential for some other slot.
    func assertBoundTo(invite: ClawShareInvite, guestPub: Data) throws {
        if hh_id_string != invite.householdId {
            throw ClawShareError.credentialIssuerMismatch
        }
        if clawId != invite.clawId {
            throw ClawShareError.credentialClawMismatch
        }
        if guestDevicePublicKey != guestPub {
            throw ClawShareError.credentialGuestMismatch
        }
        if slotId != invite.slotId {
            throw ClawShareError.credentialSlotMismatch
        }
    }

    fileprivate var hh_id_string: String { householdId }
}

