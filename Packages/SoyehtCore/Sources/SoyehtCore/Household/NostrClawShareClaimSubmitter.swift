import Foundation
import CryptoKit
import P256K
import os

/// Production claim transport for iOS: publish the encrypted
/// `ClawShareClaim` to every relay in `invite.claimRelays` in
/// parallel and accept the first valid ack. Backed by a persistent
/// outbox so an iOS background kill mid-publish doesn't lose the
/// claim — the next launch drains the outbox before any new
/// submission.
///
/// Multi-relay fanout: a relay being dead can never make a valid
/// invite look broken. We connect to every relay listed on the
/// invite concurrently; on the FIRST relay that returns a valid ack
/// the other siblings are cancelled. If every relay fails (TCP
/// refused, WS handshake aborted, ack timed out, etc.) the
/// submission throws and the outbox record is left for a future
/// retry.
///
/// Idempotency model:
/// - Each pending claim has a stable `slot_id` (16 bytes from the
///   invite). The engine slot store rejects double-consume by the
///   same `slot_id` regardless of how many times the friend
///   publishes — see `ClawShareSlotStore` on the Rust side. The
///   outbox keys by `slot_id.hex` so a relaunch never duplicates a
///   pending publish.
/// - Each Nostr event ID is the canonical SHA256(NIP-01 payload).
///   Same plaintext + same nonce → same event id. Relays dedupe.
public actor NostrClawShareClaimSubmitter: ClawShareClaimSubmitter {
    public typealias TransportFactory = @Sendable (URL) async throws -> any NostrWireTransport

    private let outbox: ClawShareClaimOutbox
    private let connectTimeout: TimeInterval
    private let ackTimeout: TimeInterval
    private let transportFactory: TransportFactory
    private let logger = Logger(subsystem: "com.soyeht.mobile", category: "nostr-claim")

    public init(
        outbox: ClawShareClaimOutbox = .applicationSupport(),
        connectTimeout: TimeInterval = 8,
        ackTimeout: TimeInterval = 20,
        transportFactory: @escaping TransportFactory = NostrClawShareClaimSubmitter.defaultTransportFactory
    ) {
        self.outbox = outbox
        self.connectTimeout = connectTimeout
        self.ackTimeout = ackTimeout
        self.transportFactory = transportFactory
    }

    /// Production default: URLSession-backed WSS.
    @Sendable
    public static func defaultTransportFactory(url: URL) async throws -> any NostrWireTransport {
        let t = URLSessionWebSocketTransport(url: url)
        await t.connect()
        return t
    }

    public func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        // ─── 1. Guest identity ────────────────────────────────────────────
        let guestIdentity: any ClawShareGuestIdentity
        do {
            guestIdentity = try identityProvider.create()
        } catch {
            throw ClawShareError.inviteMalformed
        }
        let guestPubBytes = guestIdentity.publicKeyData
        guard guestPubBytes.count == 33 else { throw ClawShareError.inviteMalformed }

        // ─── 2. Build signed claim envelope ───────────────────────────────
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
        guard guestSignature.count == 64 else { throw ClawShareError.inviteMalformed }
        let claim = ClawShareClaim(
            slotId: invite.slotId,
            guestDevicePublicKey: guestPubBytes,
            nonce: nonce,
            timestamp: timestamp,
            guestSignature: guestSignature
        )
        let claimCBOR = ClawShareCodec.encode(claim)

        // ─── 3. Persist BEFORE network — kill-resilience ──────────────────
        let record = ClawShareClaimOutbox.Record(
            slotIdHex: invite.slotId.hexEncodedString(),
            inviteCBOR: ClawShareCodec.encode(invite),
            claimCBOR: claimCBOR,
            createdAt: timestamp,
            attempts: 0
        )
        try await outbox.upsert(record)

        // ─── 4. Friend Nostr keypair (ephemeral per claim) + ECDH ─────────
        let friendNostrPriv = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let friendXonlyBytes = try P256K.Schnorr.PrivateKey(dataRepresentation: friendNostrPriv)
            .xonly.bytes
        let friendXonly = Data(friendXonlyBytes)
        let friendXonlyHex = friendXonly.hexEncodedString()
        let engineCompressedPub = try Self.decodeEngineNpubToCompressed(invite.ownerEngineNpub)
        let engineXonlyHex = engineCompressedPub.subdata(in: 1..<33).hexEncodedString()

        // ─── 5. Encrypt claim CBOR with NIP-44 v2 ─────────────────────────
        let nip44Nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let ciphertextBase64 = try NostrNIP44.encrypt(
            plaintext: claimCBOR,
            myPrivKey: friendNostrPriv,
            peerPubKey: engineCompressedPub,
            nonce: nip44Nonce
        )

        // ─── 6. Sign gift-wrap event (kind 1059, #p = engine xonly) ───────
        let event = try NostrEventSigning.sign(
            privateKey: friendNostrPriv,
            pubkey: friendXonlyHex,
            createdAt: UInt64(Date().timeIntervalSince1970),
            kind: 1059,
            tags: [["p", engineXonlyHex]],
            content: ciphertextBase64
        )

        // ─── 7. Multi-relay fanout: race ack across every relay ──────────
        let relayURLs = invite.claimRelays.compactMap(URL.init(string:))
        guard !relayURLs.isEmpty else { throw ClawShareError.transportClosed }
        let subId = "ack-\(invite.slotId.hexEncodedString())"
        let ackEvent = try await raceForAck(
            relayURLs: relayURLs,
            event: event,
            subscriptionFilter: [
                "kinds": [1059],
                "#p": [friendXonlyHex],
                "since": Int(Date().timeIntervalSince1970) - 5,
            ],
            subId: subId
        )

        // ─── 8. Decrypt ack and verify binding ───────────────────────────
        let ackPlaintext: Data
        do {
            ackPlaintext = try NostrNIP44.decrypt(
                payloadBase64: ackEvent.content,
                myPrivKey: friendNostrPriv,
                peerPubKey: engineCompressedPub
            )
        } catch {
            throw ClawShareError.unexpectedFrame
        }
        let ack = try Self.decodeAck(ackPlaintext)
        try ack.credential.assertBoundTo(invite: invite, guestPub: guestPubBytes)

        // ─── 9. Success: drop outbox record ───────────────────────────────
        try await outbox.remove(slotIdHex: invite.slotId.hexEncodedString())

        return ClaimedSession(
            credential: ack.credential,
            tunnel: ack.tunnel,
            guestIdentity: guestIdentity
        )
    }

    /// Fan out subscribe+publish across all relays in parallel.
    /// First valid ack wins; siblings are cancelled. If every relay
    /// fails, throws `.transportClosed`.
    ///
    /// Subscribe-before-publish: each per-relay task installs the
    /// subscription BEFORE publishing the claim, so the engine's
    /// ack (which travels via the same relay) cannot race past us.
    private func raceForAck(
        relayURLs: [URL],
        event: NostrEvent,
        subscriptionFilter: [String: Any],
        subId: String
    ) async throws -> NostrEvent {
        let timeoutSec = ackTimeout
        let factory = transportFactory
        let logger = self.logger
        return try await withThrowingTaskGroup(of: Result<NostrEvent, Error>.self) { group in
            for url in relayURLs {
                group.addTask { @Sendable in
                    do {
                        let ev = try await Self.singleRelayAttempt(
                            url: url,
                            event: event,
                            filter: subscriptionFilter,
                            subId: subId,
                            timeoutSec: timeoutSec,
                            transportFactory: factory,
                            logger: logger
                        )
                        return .success(ev)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var lastError: Error = ClawShareError.transportClosed
            for try await result in group {
                switch result {
                case .success(let ev):
                    group.cancelAll()
                    return ev
                case .failure(let e):
                    lastError = e
                }
            }
            throw lastError
        }
    }

    private static func singleRelayAttempt(
        url: URL,
        event: NostrEvent,
        filter: [String: Any],
        subId: String,
        timeoutSec: TimeInterval,
        transportFactory: @escaping TransportFactory,
        logger: Logger
    ) async throws -> NostrEvent {
        let transport: any NostrWireTransport
        do {
            transport = try await transportFactory(url)
        } catch {
            logger.warning("nostr_relay_connect_failed url=\(url.absoluteString, privacy: .public) err=\(String(describing: error), privacy: .public)")
            throw ClawShareError.transportClosed
        }
        let client = NostrWSSClient(transport: transport, ackTimeout: timeoutSec)
        try await client.connect()
        defer { Task { await client.close() } }

        let stream: AsyncStream<NostrEvent>
        do {
            stream = try await client.subscribe(id: subId, filter: filter)
        } catch {
            logger.warning("nostr_relay_subscribe_failed url=\(url.absoluteString, privacy: .public) err=\(String(describing: error), privacy: .public)")
            throw ClawShareError.transportClosed
        }
        do {
            try await client.publish(event)
        } catch {
            // Publish rejection doesn't necessarily mean the engine
            // won't ack: relays sometimes return OK with accepted=false
            // for duplicates. Still wait for ack — siblings may also
            // succeed.
            logger.info("nostr_relay_publish_failed url=\(url.absoluteString, privacy: .public) err=\(String(describing: error), privacy: .public)")
        }

        do {
            return try await Self.waitForAck(stream: stream, deadline: timeoutSec)
        } catch {
            logger.warning("nostr_relay_wait_ack_failed url=\(url.absoluteString, privacy: .public) err=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func waitForAck(
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

    private static func decodeEngineNpubToCompressed(_ npub: String) throws -> Data {
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

extension GuestCredential {
    func assertBoundTo(invite: ClawShareInvite, guestPub: Data) throws {
        if householdId != invite.householdId {
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
}
