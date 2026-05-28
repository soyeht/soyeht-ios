import Foundation

/// Canonical CBOR encode/decode + URI for the claw-share wire envelopes.
///
/// Pairs with `household_rs::claw_share` on the host. The CBOR shape is
/// byte-equal across both sides so signatures verify after a round trip
/// through this codec. URI scheme matches `CLAW_SHARE_URI_PREFIX` on the
/// host (`soyeht://claw-share/v1?e=`).
///
/// Encoding is via the existing [`HouseholdCBOR`] map helper (lex-ordered
/// keys, definite lengths) — no new CBOR machinery introduced.

// MARK: - URI prefix

public enum ClawShareURI {
    public static let prefix = "soyeht://claw-share/v1?e="
}

// MARK: - Tunnel handle ↔ CBOR

extension ClawShareTunnelHandle {
    fileprivate var cborValue: HouseholdCBORValue {
        switch self {
        case .loopback(let channel):
            return .map([
                "channel": .text(channel),
                "kind": .text("loopback"),
            ])
        case .fips(let peerNpub, let hint):
            var map: [String: HouseholdCBORValue] = [
                "kind": .text("fips"),
                "peer_npub": .text(peerNpub),
            ]
            // `serde` emits the `Option<String>` field unconditionally —
            // present as `.null` when None on the host. Mirror that so
            // the encoded bytes match.
            if let hint {
                map["hint"] = .text(hint)
            } else {
                map["hint"] = .null
            }
            return .map(map)
        }
    }

    fileprivate static func decode(_ value: HouseholdCBORValue) throws -> ClawShareTunnelHandle {
        let map = try ClawShareCodec.expectMap(value)
        let kind = try ClawShareCodec.expectText(map["kind"])
        switch kind {
        case "loopback":
            let channel = try ClawShareCodec.expectText(map["channel"])
            return .loopback(channel: channel)
        case "fips":
            let peerNpub = try ClawShareCodec.expectText(map["peer_npub"])
            let hint: String?
            switch map["hint"] {
            case .some(.text(let s)): hint = s
            case .some(.null), .none:  hint = nil
            default: throw ClawShareError.inviteMalformed
            }
            return .fips(peerNpub: peerNpub, hint: hint)
        default:
            throw ClawShareError.inviteMalformed
        }
    }
}

// MARK: - Codec entrypoints

public enum ClawShareCodec {
    // ─── Invite ──────────────────────────────────────────────────────────

    public static func encode(_ invite: ClawShareInvite) -> Data {
        HouseholdCBOR.encode(.map([
            "claw_id": .text(invite.clawId),
            "expires_at": .unsigned(invite.expiresAt),
            "hh_id": .text(invite.householdId),
            "kind": .text(invite.kind),
            "owner_p_id": .text(invite.ownerPersonId),
            "owner_p_pub": .bytes(invite.ownerPublicKey),
            "owner_signature": .bytes(invite.ownerSignature),
            "slot_id": .bytes(invite.slotId),
            "transport_hint": invite.transportHint.cborValue,
            "v": .unsigned(UInt64(invite.v)),
        ]))
    }

    public static func decodeInvite(_ data: Data) throws -> ClawShareInvite {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(data)
        } catch {
            throw ClawShareError.inviteMalformed
        }
        let map = try expectMap(value)
        return ClawShareInvite(
            v: try expectUInt8(map["v"]),
            kind: try expectText(map["kind"]),
            householdId: try expectText(map["hh_id"]),
            ownerPersonId: try expectText(map["owner_p_id"]),
            ownerPublicKey: try expectBytes(map["owner_p_pub"]),
            clawId: try expectText(map["claw_id"]),
            slotId: try expectBytes(map["slot_id"]),
            transportHint: try ClawShareTunnelHandle.decode(map["transport_hint"] ?? .null),
            expiresAt: try expectUInt64(map["expires_at"]),
            ownerSignature: try expectBytes(map["owner_signature"])
        )
    }

    // ─── Claim ───────────────────────────────────────────────────────────

    public static func encode(_ claim: ClawShareClaim) -> Data {
        HouseholdCBOR.encode(.map([
            "guest_device_pub": .bytes(claim.guestDevicePublicKey),
            "guest_signature": .bytes(claim.guestSignature),
            "kind": .text(claim.kind),
            "nonce": .bytes(claim.nonce),
            "slot_id": .bytes(claim.slotId),
            "timestamp": .unsigned(claim.timestamp),
            "v": .unsigned(UInt64(claim.v)),
        ]))
    }

    public static func decodeClaim(_ data: Data) throws -> ClawShareClaim {
        let value: HouseholdCBORValue
        do { value = try HouseholdCBOR.decode(data) }
        catch { throw ClawShareError.inviteMalformed }
        let map = try expectMap(value)
        return ClawShareClaim(
            v: try expectUInt8(map["v"]),
            kind: try expectText(map["kind"]),
            slotId: try expectBytes(map["slot_id"]),
            guestDevicePublicKey: try expectBytes(map["guest_device_pub"]),
            nonce: try expectBytes(map["nonce"]),
            timestamp: try expectUInt64(map["timestamp"]),
            guestSignature: try expectBytes(map["guest_signature"])
        )
    }

    // ─── Credential ──────────────────────────────────────────────────────

    public static func encode(_ credential: GuestCredential) -> Data {
        HouseholdCBOR.encode(.map([
            "claw_id": .text(credential.clawId),
            "expires_at": .unsigned(credential.expiresAt),
            "guest_device_pub": .bytes(credential.guestDevicePublicKey),
            "hh_id": .text(credential.householdId),
            "issued_at": .unsigned(credential.issuedAt),
            "kind": .text(credential.kind),
            "owner_p_id": .text(credential.ownerPersonId),
            "owner_p_pub": .bytes(credential.ownerPublicKey),
            "owner_signature": .bytes(credential.ownerSignature),
            "slot_id": .bytes(credential.slotId),
            "v": .unsigned(UInt64(credential.v)),
        ]))
    }

    public static func decodeCredential(_ data: Data) throws -> GuestCredential {
        let value: HouseholdCBORValue
        do { value = try HouseholdCBOR.decode(data) }
        catch { throw ClawShareError.inviteMalformed }
        let map = try expectMap(value)
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

    // ─── Ack ─────────────────────────────────────────────────────────────

    public static func encode(_ ack: ClawShareAck) -> Data {
        HouseholdCBOR.encode(.map([
            "credential": cborValueOfCredential(ack.credential),
            "tunnel": ack.tunnel.cborValue,
            "v": .unsigned(UInt64(ack.v)),
        ]))
    }

    public static func decodeAck(_ data: Data) throws -> ClawShareAck {
        let value: HouseholdCBORValue
        do { value = try HouseholdCBOR.decode(data) }
        catch { throw ClawShareError.inviteMalformed }
        let map = try expectMap(value)
        // Re-encode the nested credential map back to bytes so we can use
        // the same `decodeCredential` path that already validates field
        // shapes. Avoids duplicating extraction logic across two sites.
        let credentialBytes = HouseholdCBOR.encode(map["credential"] ?? .null)
        let credential = try decodeCredential(credentialBytes)
        let tunnel = try ClawShareTunnelHandle.decode(map["tunnel"] ?? .null)
        return ClawShareAck(
            v: try expectUInt8(map["v"]),
            credential: credential,
            tunnel: tunnel
        )
    }

    // ─── URI ─────────────────────────────────────────────────────────────

    public static func inviteURI(_ invite: ClawShareInvite) -> String {
        let cbor = encode(invite)
        return "\(ClawShareURI.prefix)\(base64URLNoPad(cbor))"
    }

    public static func decodeInviteURI(_ uri: String) throws -> ClawShareInvite {
        guard uri.hasPrefix(ClawShareURI.prefix) else {
            throw ClawShareError.inviteMalformed
        }
        let encoded = String(uri.dropFirst(ClawShareURI.prefix.count))
        guard let cbor = base64URLNoPadDecode(encoded) else {
            throw ClawShareError.inviteMalformed
        }
        return try decodeInvite(cbor)
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    fileprivate static func cborValueOfCredential(_ credential: GuestCredential) -> HouseholdCBORValue {
        guard case .map(let inner) = try? HouseholdCBOR.decode(encode(credential)) else {
            // Encoder always emits a map; this branch is unreachable.
            return .null
        }
        return .map(inner)
    }

    fileprivate static func expectMap(_ value: HouseholdCBORValue?) throws -> [String: HouseholdCBORValue] {
        guard case .some(.map(let m)) = value else { throw ClawShareError.inviteMalformed }
        return m
    }

    fileprivate static func expectText(_ value: HouseholdCBORValue?) throws -> String {
        guard case .some(.text(let t)) = value else { throw ClawShareError.inviteMalformed }
        return t
    }

    fileprivate static func expectBytes(_ value: HouseholdCBORValue?) throws -> Data {
        guard case .some(.bytes(let b)) = value else { throw ClawShareError.inviteMalformed }
        return b
    }

    fileprivate static func expectUInt8(_ value: HouseholdCBORValue?) throws -> UInt8 {
        guard case .some(.unsigned(let n)) = value, n <= UInt64(UInt8.max) else {
            throw ClawShareError.inviteMalformed
        }
        return UInt8(n)
    }

    fileprivate static func expectUInt64(_ value: HouseholdCBORValue?) throws -> UInt64 {
        guard case .some(.unsigned(let n)) = value else { throw ClawShareError.inviteMalformed }
        return n
    }

    // ─── base64url-no-pad ────────────────────────────────────────────────

    fileprivate static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate static func base64URLNoPadDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore padding so Foundation's decoder accepts it.
        let remainder = s.count % 4
        if remainder > 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: s)
    }
}
