import CryptoKit
import Foundation
import P256K
import Security

public actor NostrClawShareClaimSubmitter: ClawShareClaimSubmitter, ClawShareGroupOfferClaimSubmitter {
    public typealias TransportFactory = @Sendable (URL) async throws -> any NostrWireTransport
    public typealias RandomBytes = @Sendable (Int) throws -> Data
    public typealias Now = @Sendable () -> Date

    private let ackTimeout: TimeInterval
    private let transportFactory: TransportFactory
    private let randomBytes: RandomBytes
    private let now: Now

    public init(
        ackTimeout: TimeInterval = 30,
        transportFactory: @escaping TransportFactory = NostrClawShareClaimSubmitter.defaultTransportFactory,
        randomBytes: @escaping RandomBytes = { count in
            try NostrClawShareClaimSubmitter.secureRandomBytes(count: count)
        },
        now: @escaping Now = { Date() }
    ) {
        self.ackTimeout = ackTimeout
        self.transportFactory = transportFactory
        self.randomBytes = randomBytes
        self.now = now
    }

    @Sendable
    public static func defaultTransportFactory(url: URL) async throws -> any NostrWireTransport {
        let transport = URLSessionWebSocketTransport(url: url)
        await transport.connect()
        return transport
    }

    public func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        let nowUnix = UInt64(max(0, now().timeIntervalSince1970))
        try verifyInvite(invite, nowUnix: nowUnix)
        let guestIdentity = try identityProvider.create()
        let guestPublicKey = guestIdentity.publicKeyData
        guard guestPublicKey.count == 33 else { throw ClawShareError.inviteMalformed }

        let claim = try signedClaim(invite: invite, guestIdentity: guestIdentity, timestamp: nowUnix)
        let slotIdHex = invite.slotId.soyehtHexEncodedString()
        let ackCBOR = try await publishClaimAndReceiveAckCBOR(
            claim: claim,
            ownerEngineNpub: invite.ownerEngineNpub,
            claimRelays: invite.claimRelays,
            subId: "ack-\(slotIdHex)"
        )
        let ack = try decodeAck(ackCBOR)
        try verifyCredential(ack.credential, expectedOwnerPublicKey: invite.ownerPublicKey, nowUnix: nowUnix)
        try ack.credential.assertBoundTo(invite: invite, guestPublicKey: guestPublicKey)

        let offer = try verifiedRelayStreamOffer(
            from: ack,
            nowUnix: nowUnix
        )
        return ClaimedSession(
            credential: ack.credential,
            tunnel: ack.tunnel,
            relayStreamOffer: offer,
            guestIdentity: guestIdentity
        )
    }

    public func submitGroupOffer(
        context: ClawShareGroupOfferClaimContext,
        memberIdentityProvider: any ClawShareMemberIdentityProviding,
        guestIdentityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedGroupRelayStreamOffer {
        let nowUnix = UInt64(max(0, now().timeIntervalSince1970))
        let memberIdentity = try memberIdentityProvider.loadOrCreate()
        let guestIdentity = try guestIdentityProvider.create()
        let nonce = try randomBytes(32)
        let request = try RelayOfferGroupRequest.build(
            challenge: nonce,
            memberIdentity: memberIdentity,
            deviceIdentity: guestIdentity,
            participantNpub: context.participantNpub,
            groupId: context.groupId,
            clawId: context.clawId,
            ttlSeconds: context.ttlSeconds,
            issuedAt: nowUnix
        )
        let claim = try ClawShareClaim.signGroup(
            groupRequest: GroupClaimRequest(relayOfferGroupRequest: request),
            guestIdentity: guestIdentity,
            nonce: nonce,
            timestamp: nowUnix
        )
        let ackCBOR = try await publishClaimAndReceiveAckCBOR(
            claim: claim,
            ownerEngineNpub: context.ownerEngineNpub,
            claimRelays: context.claimRelays,
            subId: "group-ack-\(nonce.soyehtHexEncodedString())"
        )
        let ack = try decodeGroupAck(ackCBOR)
        let offer = try verifiedGroupRelayStreamOffer(
            from: ack,
            expectedOwnerPublicKey: context.ownerPublicKey,
            expectedGuestPublicKey: guestIdentity.publicKeyData,
            expectedGroupId: context.groupId,
            expectedMemberId: memberIdentity.memberId,
            expectedClawId: context.clawId,
            nowUnix: nowUnix
        )
        return ClaimedGroupRelayStreamOffer(
            relayStreamOffer: offer,
            guestIdentity: guestIdentity,
            ownerPublicKey: context.ownerPublicKey,
            groupId: context.groupId,
            memberId: memberIdentity.memberId,
            clawId: context.clawId
        )
    }

    private func signedClaim(
        invite: ClawShareInvite,
        guestIdentity: any ClawShareGuestIdentity,
        timestamp: UInt64
    ) throws -> ClawShareClaim {
        let nonce = try randomBytes(32)
        let signingBytes = ClawShareCodec.canonicalClaimSigningBytes(
            slotId: invite.slotId,
            guestDevicePublicKey: guestIdentity.publicKeyData,
            nonce: nonce,
            timestamp: timestamp,
            participantNpub: nil
        )
        let signature = try guestIdentity.sign(signingBytes)
        guard signature.count == 64 else { throw ClawShareError.inviteMalformed }
        return ClawShareClaim(
            slotId: invite.slotId,
            guestDevicePublicKey: guestIdentity.publicKeyData,
            nonce: nonce,
            timestamp: timestamp,
            participantNpub: nil,
            guestSignature: signature
        )
    }

    private func publishClaimAndReceiveAckCBOR(
        claim: ClawShareClaim,
        ownerEngineNpub: String,
        claimRelays: [String],
        subId: String
    ) async throws -> Data {
        let claimCBOR = ClawShareCodec.encode(claim)
        let friendNostrPrivateKey = try mintNostrPrivateKey()
        let friendXonly = try Data(P256K.Schnorr.PrivateKey(
            dataRepresentation: friendNostrPrivateKey
        ).xonly.bytes)
        let friendXonlyHex = friendXonly.soyehtHexEncodedString()
        let engineCompressedPublicKey = try Self.decodeEngineNpubToCompressed(ownerEngineNpub)
        let engineXonlyHex = engineCompressedPublicKey.subdata(in: 1..<33).soyehtHexEncodedString()

        let claimPlaintext = Data(claimCBOR.soyehtHexEncodedString().utf8)
        let ciphertext = try NostrNIP44.encrypt(
            plaintext: claimPlaintext,
            myPrivKey: friendNostrPrivateKey,
            peerPubKey: engineCompressedPublicKey,
            nonce: randomBytes(32)
        )
        let event = try NostrEventSigning.sign(
            privateKey: friendNostrPrivateKey,
            pubkey: friendXonlyHex,
            createdAt: UInt64(max(0, now().timeIntervalSince1970)),
            kind: 1059,
            tags: [["p", engineXonlyHex]],
            content: ciphertext
        )

        let relayURLs = claimRelays.compactMap(URL.init(string:)).filter { $0.scheme == "wss" }
        guard !relayURLs.isEmpty else { throw ClawShareError.transportClosed }

        let ackEvent = try await raceForAck(
            relayURLs: relayURLs,
            event: event,
            subscriptionFilter: [
                "kinds": [1059],
                "#p": [friendXonlyHex],
                "since": Int(now().timeIntervalSince1970) - 5,
            ],
            subId: subId
        )
        return try decryptAckCBOR(
            event: ackEvent,
            friendNostrPrivateKey: friendNostrPrivateKey,
            engineCompressedPublicKey: engineCompressedPublicKey
        )
    }

    private func raceForAck(
        relayURLs: [URL],
        event: NostrEvent,
        subscriptionFilter: [String: Any],
        subId: String
    ) async throws -> NostrEvent {
        try await withThrowingTaskGroup(of: Result<NostrEvent, Error>.self) { group in
            for relayURL in relayURLs {
                let factory = transportFactory
                let timeout = ackTimeout
                group.addTask {
                    let clientBox = NostrClientCloseBox()
                    return await withTaskCancellationHandler {
                        do {
                            let transport = try await factory(relayURL)
                            let client = NostrWSSClient(transport: transport, ackTimeout: timeout)
                            await clientBox.set(client)
                            try await client.connect()
                            let stream = try await client.subscribe(id: subId, filter: subscriptionFilter)
                            async let published: Void = client.publish(event)
                            async let ack: NostrEvent = Self.waitForAck(stream: stream, timeout: timeout)
                            let (_, event) = try await (published, ack)
                            await client.close()
                            return .success(event)
                        } catch {
                            await clientBox.close()
                            return .failure(error)
                        }
                    } onCancel: {
                        Task {
                            await clientBox.close()
                        }
                    }
                }
            }

            var lastError: Error = ClawShareError.transportClosed
            for try await result in group {
                switch result {
                case .success(let event):
                    group.cancelAll()
                    return event
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func waitForAck(
        stream: AsyncStream<NostrEvent>,
        timeout: TimeInterval
    ) async throws -> NostrEvent {
        try await withThrowingTaskGroup(of: NostrEvent.self) { group in
            group.addTask {
                for await event in stream where event.kind == 1059 {
                    return event
                }
                throw ClawShareError.transportClosed
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ClawShareError.ackTimedOut
            }
            guard let first = try await group.next() else {
                throw ClawShareError.transportClosed
            }
            group.cancelAll()
            return first
        }
    }

    private func decryptAckCBOR(
        event: NostrEvent,
        friendNostrPrivateKey: Data,
        engineCompressedPublicKey: Data
    ) throws -> Data {
        let plaintext = try NostrNIP44.decrypt(
            payloadBase64: event.content,
            myPrivKey: friendNostrPrivateKey,
            peerPubKey: engineCompressedPublicKey
        )
        guard let hex = String(data: plaintext, encoding: .utf8),
              let ackCBOR = Data(soyehtHex: hex)
        else {
            throw ClawShareError.unexpectedFrame
        }
        return ackCBOR
    }

    private static func decodeEngineNpubToCompressed(_ value: String) throws -> Data {
        let trimmed = value.hasPrefix("npub_") ? String(value.dropFirst("npub_".count)) : value
        guard let xonly = Data(soyehtHex: trimmed), xonly.count == 32 else {
            throw ClawShareError.inviteMalformed
        }
        var compressed = Data([0x02])
        compressed.append(xonly)
        return compressed
    }

    private func mintNostrPrivateKey() throws -> Data {
        for _ in 0..<16 {
            let scalar = try randomBytes(32)
            if (try? P256K.Schnorr.PrivateKey(dataRepresentation: scalar)) != nil,
               (try? P256K.KeyAgreement.PrivateKey(dataRepresentation: scalar)) != nil {
                return scalar
            }
        }
        throw ClawShareError.inviteMalformed
    }

    private func decodeAck(_ data: Data) throws -> ClawShareAck {
        do {
            return try ClawShareCodec.decodeAck(data)
        } catch {
            throw ClawShareError.unexpectedFrame
        }
    }

    private func decodeGroupAck(_ data: Data) throws -> ClawShareGroupAck {
        do {
            return try ClawShareCodec.decodeGroupAck(data)
        } catch {
            throw ClawShareError.unexpectedFrame
        }
    }

    private func verifiedRelayStreamOffer(
        from ack: ClawShareAck,
        nowUnix: UInt64
    ) throws -> RelayStreamOfferContract? {
        guard let bytes = ack.relayStreamOfferBytes else { return nil }
        let offer = try RelayStreamOfferContract.fromCanonicalBytes(bytes)
        do {
            try offer.verifyRelayStreamGuest(
                credential: ack.credential,
                nowUnix: nowUnix
            )
        } catch {
            throw ClawShareError.relayStreamOfferRejected
        }
        return offer
    }

    private func verifiedGroupRelayStreamOffer(
        from ack: ClawShareGroupAck,
        expectedOwnerPublicKey: Data,
        expectedGuestPublicKey: Data,
        expectedGroupId: String,
        expectedMemberId: String,
        expectedClawId: String,
        nowUnix: UInt64
    ) throws -> RelayStreamOfferContract {
        let offer = try RelayStreamOfferContract.fromCanonicalBytes(ack.relayStreamOfferBytes)
        do {
            try offer.verifyRelayStreamGuest(
                expectedSignerPublicKey: expectedOwnerPublicKey,
                expectedGuestDevicePublicKey: expectedGuestPublicKey,
                nowUnix: nowUnix
            )
            guard offer.payload.clawId == expectedClawId else {
                throw RelayStreamOfferError.credentialClawMismatch
            }
            guard case .group(let groupId, let memberId) = offer.payload.audience,
                  groupId == expectedGroupId,
                  memberId == expectedMemberId
            else {
                throw RelayStreamOfferError.audienceMismatch
            }
        } catch {
            throw ClawShareError.relayStreamOfferRejected
        }
        return offer
    }

    public static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ClawShareError.transportClosed }
        return data
    }
}

private actor NostrClientCloseBox {
    private var client: NostrWSSClient?

    func set(_ client: NostrWSSClient) {
        self.client = client
    }

    func close() async {
        await client?.close()
        client = nil
    }
}

private func verifyCredential(
    _ credential: GuestCredential,
    expectedOwnerPublicKey: Data,
    nowUnix: UInt64
) throws {
    guard credential.ownerPublicKey == expectedOwnerPublicKey else {
        throw ClawShareError.credentialIssuerMismatch
    }
    guard credential.expiresAt > nowUnix else {
        throw ClawShareError.credentialExpired
    }
    let publicKey: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
        publicKey = try P256.Signing.PublicKey(compressedRepresentation: credential.ownerPublicKey)
        signature = try P256.Signing.ECDSASignature(rawRepresentation: credential.ownerSignature)
    } catch {
        throw ClawShareError.credentialSignatureRejected
    }
    guard publicKey.isValidSignature(
        signature,
        for: ClawShareCodec.canonicalCredentialSigningBytes(credential)
    ) else {
        throw ClawShareError.credentialSignatureRejected
    }
}

private func verifyInvite(_ invite: ClawShareInvite, nowUnix: UInt64) throws {
    guard invite.v == ClawShareInvite.currentVersion,
          invite.kind == ClawShareInvite.kind,
          invite.slotId.count == 16,
          invite.ownerPublicKey.count == 33,
          invite.ownerSignature.count == 64
    else {
        throw ClawShareError.inviteMalformed
    }
    guard invite.expiresAt > nowUnix else {
        throw ClawShareError.inviteExpired
    }
    let publicKey: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
        publicKey = try P256.Signing.PublicKey(compressedRepresentation: invite.ownerPublicKey)
        signature = try P256.Signing.ECDSASignature(rawRepresentation: invite.ownerSignature)
    } catch {
        throw ClawShareError.inviteSignatureRejected
    }
    guard publicKey.isValidSignature(
        signature,
        for: ClawShareCodec.canonicalInviteSigningBytes(invite)
    ) else {
        throw ClawShareError.inviteSignatureRejected
    }
}
