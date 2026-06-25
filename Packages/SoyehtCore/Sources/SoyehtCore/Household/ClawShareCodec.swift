import Foundation

public enum ClawShareURI {
    public static let prefix = "soyeht://claw-share/v1?e="
}

extension ClawShareTunnelHandle {
    fileprivate var cborValue: HouseholdCBORValue {
        switch self {
        case .loopback(let channel):
            return .map([
                "channel": .text(channel),
                "kind": .text("loopback"),
            ])
        case .direct(let host, let port):
            return .map([
                "host": .text(host),
                "kind": .text("direct"),
                "port": .unsigned(UInt64(port)),
            ])
        }
    }

    fileprivate static func decode(_ value: HouseholdCBORValue?) throws -> ClawShareTunnelHandle {
        let map = try ClawShareCodec.expectMap(value)
        let kind = try ClawShareCodec.expectText(map["kind"])
        switch kind {
        case "loopback":
            return .loopback(channel: try ClawShareCodec.expectText(map["channel"]))
        case "direct":
            let port = try ClawShareCodec.expectUInt64(map["port"])
            guard port <= UInt64(UInt16.max) else { throw ClawShareError.inviteMalformed }
            return .direct(host: try ClawShareCodec.expectText(map["host"]), port: UInt16(port))
        default:
            throw ClawShareError.inviteMalformed
        }
    }
}

public enum ClawShareCodec {
    public static func encode(_ invite: ClawShareInvite) -> Data {
        HouseholdCBOR.encode(.map(inviteMap(invite, includeSignature: true)))
    }

    public static func decodeInvite(_ data: Data) throws -> ClawShareInvite {
        let map = try decodeMap(data)
        let relayValues: [HouseholdCBORValue]
        switch map["claim_relays"] {
        case .some(.array(let values)):
            relayValues = values
        case .none:
            relayValues = []
        default:
            throw ClawShareError.inviteMalformed
        }
        return ClawShareInvite(
            v: try expectUInt8(map["v"]),
            kind: try expectText(map["kind"]),
            householdId: try expectText(map["hh_id"]),
            ownerPersonId: try expectText(map["owner_p_id"]),
            ownerPublicKey: try expectBytes(map["owner_p_pub"]),
            clawId: try expectText(map["claw_id"]),
            slotId: try expectBytes(map["slot_id"]),
            transportHint: try ClawShareTunnelHandle.decode(map["transport_hint"]),
            expiresAt: try expectUInt64(map["expires_at"]),
            ownerEngineNpub: try expectText(map["owner_engine_npub"]),
            claimRelays: try relayValues.map { try expectText($0) },
            ownerSignature: try expectBytes(map["owner_signature"])
        )
    }

    public static func encode(_ claim: ClawShareClaim) -> Data {
        var fields: [String: HouseholdCBORValue] = [
            "guest_device_pub": .bytes(claim.guestDevicePublicKey),
            "guest_signature": .bytes(claim.guestSignature),
            "kind": .text(claim.kind),
            "nonce": .bytes(claim.nonce),
            "slot_id": .bytes(claim.slotId),
            "timestamp": .unsigned(claim.timestamp),
            "v": .unsigned(UInt64(claim.v)),
        ]
        if let participantNpub = claim.participantNpub {
            fields["participant_npub"] = .text(participantNpub)
        }
        if let groupRequest = claim.groupRequest {
            fields["group_request"] = groupRequest.cborValue
        }
        return HouseholdCBOR.encode(.map(fields))
    }

    public static func decodeClaim(_ data: Data) throws -> ClawShareClaim {
        let map = try decodeMap(data)
        let participantNpub: String?
        switch map["participant_npub"] {
        case .some(.text(let value)):
            participantNpub = value
        case .none:
            participantNpub = nil
        default:
            throw ClawShareError.inviteMalformed
        }
        let groupRequest: GroupClaimRequest?
        switch map["group_request"] {
        case .some(let value):
            groupRequest = try GroupClaimRequest.decode(value)
        case .none:
            groupRequest = nil
        }
        return ClawShareClaim(
            v: try expectUInt8(map["v"]),
            kind: try expectText(map["kind"]),
            slotId: try expectBytes(map["slot_id"]),
            guestDevicePublicKey: try expectBytes(map["guest_device_pub"]),
            nonce: try expectBytes(map["nonce"]),
            timestamp: try expectUInt64(map["timestamp"]),
            participantNpub: participantNpub,
            groupRequest: groupRequest,
            guestSignature: try expectBytes(map["guest_signature"])
        )
    }

    public static func encode(_ credential: GuestCredential) -> Data {
        HouseholdCBOR.encode(.map(credentialMap(credential, includeSignature: true)))
    }

    public static func decodeCredential(_ data: Data) throws -> GuestCredential {
        let map = try decodeMap(data)
        return GuestCredential(
            v: try expectUInt8(map["v"]),
            kind: try expectText(map["kind"]),
            householdId: try expectText(map["hh_id"]),
            ownerPersonId: try expectText(map["owner_p_id"]),
            ownerPublicKey: try expectBytes(map["owner_p_pub"]),
            clawId: try expectText(map["claw_id"]),
            guestDevicePublicKey: try expectBytes(map["guest_device_pub"]),
            slotId: try expectBytes(map["slot_id"]),
            issuedAt: try expectUInt64(map["issued_at"]),
            expiresAt: try expectUInt64(map["expires_at"]),
            ownerSignature: try expectBytes(map["owner_signature"])
        )
    }

    public static func encode(_ ack: ClawShareAck) -> Data {
        var fields: [String: HouseholdCBORValue] = [
            "credential": .map(credentialMap(ack.credential, includeSignature: true)),
            "tunnel": ack.tunnel.cborValue,
            "v": .unsigned(UInt64(ack.v)),
        ]
        if let relayStreamOfferBytes = ack.relayStreamOfferBytes {
            fields["relay_stream_offer"] = .bytes(relayStreamOfferBytes)
        }
        return HouseholdCBOR.encode(.map(fields))
    }

    public static func decodeAck(_ data: Data) throws -> ClawShareAck {
        let map = try decodeMap(data)
        let credential = try decodeCredential(HouseholdCBOR.encode(map["credential"] ?? .null))
        let offerBytes: Data?
        switch map["relay_stream_offer"] {
        case .some(.bytes(let bytes)):
            offerBytes = bytes
        case .none:
            offerBytes = nil
        default:
            throw ClawShareError.inviteMalformed
        }
        return ClawShareAck(
            v: try expectUInt8(map["v"]),
            credential: credential,
            tunnel: try ClawShareTunnelHandle.decode(map["tunnel"]),
            relayStreamOfferBytes: offerBytes
        )
    }

    public static func encode(_ ack: ClawShareGroupAck) -> Data {
        HouseholdCBOR.encode(.map([
            "relay_stream_offer": .bytes(ack.relayStreamOfferBytes),
            "v": .unsigned(UInt64(ack.v)),
        ]))
    }

    public static func decodeGroupAck(_ data: Data) throws -> ClawShareGroupAck {
        let map = try decodeMap(data)
        guard Set(map.keys) == ["relay_stream_offer", "v"] else {
            throw ClawShareError.inviteMalformed
        }
        return ClawShareGroupAck(
            v: try expectUInt8(map["v"]),
            relayStreamOfferBytes: try expectBytes(map["relay_stream_offer"])
        )
    }

    public static func inviteURI(_ invite: ClawShareInvite) -> String {
        "\(ClawShareURI.prefix)\(base64URLNoPad(encode(invite)))"
    }

    public static func decodeInviteURI(_ uri: String) throws -> ClawShareInvite {
        guard uri.hasPrefix(ClawShareURI.prefix) else { throw ClawShareError.inviteMalformed }
        let encoded = String(uri.dropFirst(ClawShareURI.prefix.count))
        guard let data = base64URLNoPadDecode(encoded) else { throw ClawShareError.inviteMalformed }
        return try decodeInvite(data)
    }

    public static func canonicalClaimSigningBytes(
        slotId: Data,
        guestDevicePublicKey: Data,
        nonce: Data,
        timestamp: UInt64,
        participantNpub: String? = nil
    ) -> Data {
        var fields: [String: HouseholdCBORValue] = [
            "guest_device_pub": .bytes(guestDevicePublicKey),
            "kind": .text(ClawShareClaim.kind),
            "nonce": .bytes(nonce),
            "slot_id": .bytes(slotId),
            "timestamp": .unsigned(timestamp),
            "v": .unsigned(1),
        ]
        if let participantNpub {
            fields["participant_npub"] = .text(participantNpub)
        }
        return HouseholdCBOR.encode(.map(fields))
    }

    public static func canonicalInviteSigningBytes(_ invite: ClawShareInvite) -> Data {
        HouseholdCBOR.encode(.map(inviteMap(invite, includeSignature: false)))
    }

    public static func canonicalCredentialSigningBytes(_ credential: GuestCredential) -> Data {
        HouseholdCBOR.encode(.map(credentialMap(credential, includeSignature: false)))
    }

    private static func credentialMap(
        _ credential: GuestCredential,
        includeSignature: Bool
    ) -> [String: HouseholdCBORValue] {
        var fields: [String: HouseholdCBORValue] = [
            "claw_id": .text(credential.clawId),
            "expires_at": .unsigned(credential.expiresAt),
            "guest_device_pub": .bytes(credential.guestDevicePublicKey),
            "hh_id": .text(credential.householdId),
            "issued_at": .unsigned(credential.issuedAt),
            "kind": .text(credential.kind),
            "owner_p_id": .text(credential.ownerPersonId),
            "owner_p_pub": .bytes(credential.ownerPublicKey),
            "slot_id": .bytes(credential.slotId),
            "v": .unsigned(UInt64(credential.v)),
        ]
        if includeSignature {
            fields["owner_signature"] = .bytes(credential.ownerSignature)
        }
        return fields
    }

    private static func inviteMap(
        _ invite: ClawShareInvite,
        includeSignature: Bool
    ) -> [String: HouseholdCBORValue] {
        var fields: [String: HouseholdCBORValue] = [
            "claim_relays": .array(invite.claimRelays.map(HouseholdCBORValue.text)),
            "claw_id": .text(invite.clawId),
            "expires_at": .unsigned(invite.expiresAt),
            "hh_id": .text(invite.householdId),
            "kind": .text(invite.kind),
            "owner_engine_npub": .text(invite.ownerEngineNpub),
            "owner_p_id": .text(invite.ownerPersonId),
            "owner_p_pub": .bytes(invite.ownerPublicKey),
            "slot_id": .bytes(invite.slotId),
            "transport_hint": invite.transportHint.cborValue,
            "v": .unsigned(UInt64(invite.v)),
        ]
        if includeSignature {
            fields["owner_signature"] = .bytes(invite.ownerSignature)
        }
        return fields
    }

    static func decodeMap(_ data: Data) throws -> [String: HouseholdCBORValue] {
        do {
            return try expectMap(HouseholdCBOR.decode(data))
        } catch {
            throw ClawShareError.inviteMalformed
        }
    }

    static func expectMap(_ value: HouseholdCBORValue?) throws -> [String: HouseholdCBORValue] {
        guard case .some(.map(let map)) = value else { throw ClawShareError.inviteMalformed }
        return map
    }

    static func expectText(_ value: HouseholdCBORValue?) throws -> String {
        guard case .some(.text(let text)) = value else { throw ClawShareError.inviteMalformed }
        return text
    }

    static func expectBytes(_ value: HouseholdCBORValue?) throws -> Data {
        guard case .some(.bytes(let bytes)) = value else { throw ClawShareError.inviteMalformed }
        return bytes
    }

    static func expectUInt8(_ value: HouseholdCBORValue?) throws -> UInt8 {
        guard case .some(.unsigned(let number)) = value, number <= UInt64(UInt8.max) else {
            throw ClawShareError.inviteMalformed
        }
        return UInt8(number)
    }

    static func expectUInt64(_ value: HouseholdCBORValue?) throws -> UInt64 {
        guard case .some(.unsigned(let number)) = value else { throw ClawShareError.inviteMalformed }
        return number
    }

    private static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLNoPadDecode(_ string: String) -> Data? {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 {
            value.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: value)
    }
}
