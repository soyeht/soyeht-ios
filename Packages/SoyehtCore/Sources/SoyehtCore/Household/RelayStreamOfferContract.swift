import CryptoKit
import Foundation

public enum RelayStreamResource: String, Sendable, Equatable {
    case pty
    case clawSite = "clawsite"
    /// Per-Claw VPN IP-packet stream. Mirrors `RelayStreamResource::IpTunnel` in
    /// the Rust wire contract (`claw_share_relay_stream_contract.rs`). Its
    /// NetworkExtension data path is gated by the stricter Group-offer
    /// verification below.
    case ipTunnel = "ip_tunnel"

    /// Resources the ordinary guest path may terminate: a terminal, or a
    /// shared app rendered in a web view.
    ///
    /// Written as an explicit literal, NOT `CaseIterable.allCases`, so adding
    /// a future case to the enum cannot silently widen what an offer is
    /// allowed to be. `ipTunnel` is excluded deliberately — it has its own
    /// entry point (`verifyRelayStreamIPTunnelGuest`) that additionally
    /// requires a Group audience, and admitting it here would bypass that.
    public static let guestSupported: Set<RelayStreamResource> = [.pty, .clawSite]
}

public enum RelayStreamExpectedPath: String, Sendable, Equatable {
    case communityRelay = "community_relay"
    case relayStream = "relay_stream"
}

public enum RelayStreamAudience: Sendable, Equatable {
    case device
    case group(groupId: String, memberId: String)
    case `public`
}

/// Slice B: the signed app presentation embedded in a Device+ClawSite offer.
/// Mirrors Rust `ShareableAppPresentation` (`claw_share_relay_stream_contract.rs`,
/// `18e35c0f`) field-for-field. A stable SNAPSHOT for presentation, never an
/// authority — routing and authorization key on `claw_id`/live checks, and a
/// later rename does not invalidate an already-issued offer.
///
/// Constructed through the throwing initializer at mint call sites
/// (`RelayStreamOfferContract.sign` does NOT validate) and re-validated by
/// `RelayStreamOfferContract.validatePayload(nowUnix:)` at verify — mirrors
/// Rust's real authority split (corrected in `82019f5b`, follow-up to
/// `18e35c0f`: the struct doc originally said "validated at mint AND
/// verify" via `payload.validate()` alone, which was imprecise — mint-time
/// validation happens through `try_new`/this throwing initializer, not by
/// calling `validate()` twice).
///
/// Structural decode (`decode(_:)`) only checks the nested key set is exactly
/// `{app_id, display_name, owner_display_name}` — matching Rust's nested
/// `#[serde(deny_unknown_fields)]`, which is load-bearing, not hygiene: an
/// ignored nested key would vanish on the re-encode signature verification
/// uses, accepting bytes that were never authenticated. Shape validation
/// (`validateShape()`) is a SEPARATE step from decode, called from
/// `RelayStreamOfferContract.validatePayload(nowUnix:)` alongside the two
/// cross-field fences — matching Rust, where `ShareableAppPresentation`'s
/// `Deserialize` derive does not run `validate()` either.
public struct ShareableAppPresentation: Sendable, Equatable {
    public let appId: String
    public let displayName: String
    public let ownerDisplayName: String

    static let idPrefix = "app_"
    static let idHexLength = 32
    static let nameMaxChars = 128

    public init(appId: String, displayName: String, ownerDisplayName: String) throws {
        try Self.validateShape(appId: appId, displayName: displayName, ownerDisplayName: ownerDisplayName)
        self.appId = appId
        self.displayName = displayName
        self.ownerDisplayName = ownerDisplayName
    }

    /// Unchecked construction for `decode(_:)` only — see the type's doc
    /// comment on why decode must not validate shape itself.
    private init(uncheckedAppId appId: String, displayName: String, ownerDisplayName: String) {
        self.appId = appId
        self.displayName = displayName
        self.ownerDisplayName = ownerDisplayName
    }

    /// Re-validates an already-constructed (or freshly-decoded) value.
    /// Needed because construction via `decode(_:)` deliberately skips shape
    /// validation (see the type's doc comment) — the caller that decides
    /// when shape rules apply (`RelayStreamOfferContract.validatePayload`)
    /// calls this explicitly.
    func validateShape() throws {
        try Self.validateShape(appId: appId, displayName: displayName, ownerDisplayName: ownerDisplayName)
    }

    private static func validateShape(appId: String, displayName: String, ownerDisplayName: String) throws {
        guard appId.hasPrefix(idPrefix) else {
            throw RelayStreamOfferError.invalidPresentation("app_id")
        }
        let hex = appId.dropFirst(idPrefix.count)
        // ASCII-only, matching Rust's `is_ascii_hexdigit()`. Swift's plain
        // `Character.isHexDigit` is Unicode-aware: it also accepts
        // non-ASCII digit-shaped characters such as U+FF11 FULLWIDTH DIGIT
        // ONE ('１'), which `.isUppercase` alone does not filter out
        // (fullwidth digits report `isUppercase == false`, same as ASCII
        // digits) -- `.isASCII` is the check that actually excludes them.
        guard hex.count == idHexLength,
              hex.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase })
        else {
            throw RelayStreamOfferError.invalidPresentation("app_id")
        }
        for (name, field) in [(displayName, "display_name"), (ownerDisplayName, "owner_display_name")] {
            // Unicode SCALAR count, matching Rust's `name.chars().count()`
            // (a Rust `char` is one scalar value) -- NOT Swift's `String.count`,
            // which counts extended grapheme CLUSTERS. A base character
            // followed by many combining marks clusters into very few
            // Swift "characters" while still being many Rust `char`s; using
            // `.count` here would let a string far longer than the real
            // limit (by scalar count, which is what Rust enforces) through.
            let length = name.unicodeScalars.count
            if length == 0 || length > nameMaxChars || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw RelayStreamOfferError.invalidPresentation(field)
            }
        }
    }

    fileprivate var cborValue: HouseholdCBORValue {
        .map([
            "app_id": .text(appId),
            "display_name": .text(displayName),
            "owner_display_name": .text(ownerDisplayName),
        ])
    }

    fileprivate static func decode(_ value: HouseholdCBORValue) throws -> ShareableAppPresentation {
        guard case .map(let map) = value else {
            throw RelayStreamOfferError.malformed
        }
        let requiredKeys: Set<String> = ["app_id", "display_name", "owner_display_name"]
        guard Set(map.keys) == requiredKeys else {
            throw RelayStreamOfferError.malformed
        }
        return try ShareableAppPresentation(
            uncheckedAppId: RelayStreamOfferContract.expectText(map["app_id"]),
            displayName: RelayStreamOfferContract.expectText(map["display_name"]),
            ownerDisplayName: RelayStreamOfferContract.expectText(map["owner_display_name"])
        )
    }
}

public struct RelayStreamOfferPayload: Sendable, Equatable {
    public static let currentVersion: UInt8 = 2
    public static let kind = "claw-share/relay-stream-offer"

    public let v: UInt8
    public let kind: String
    public let rendezvousToken: Data
    public let clawId: String
    public let slotId: Data
    public let guestDevicePublicKey: Data
    public let resource: RelayStreamResource
    public let expectedPath: RelayStreamExpectedPath
    public let relayEndpoint: String
    public let clawStaticPublicKey: Data
    public let notAfter: UInt64
    public let authz: RelayStreamAudience?
    /// Slice B (ADDITIVE, optional). See `ShareableAppPresentation`'s doc
    /// comment. `nil` is omitted from the wire, so an offer without this
    /// field keeps the exact canonical CBOR, signature, and v2 fixtures this
    /// field did not exist before it — mirrors `authz` exactly.
    public let appPresentation: ShareableAppPresentation?

    public init(
        v: UInt8 = RelayStreamOfferPayload.currentVersion,
        kind: String = RelayStreamOfferPayload.kind,
        rendezvousToken: Data,
        clawId: String,
        slotId: Data,
        guestDevicePublicKey: Data,
        resource: RelayStreamResource,
        expectedPath: RelayStreamExpectedPath,
        relayEndpoint: String,
        clawStaticPublicKey: Data,
        notAfter: UInt64,
        authz: RelayStreamAudience? = nil,
        appPresentation: ShareableAppPresentation? = nil
    ) {
        self.v = v
        self.kind = kind
        self.rendezvousToken = rendezvousToken
        self.clawId = clawId
        self.slotId = slotId
        self.guestDevicePublicKey = guestDevicePublicKey
        self.resource = resource
        self.expectedPath = expectedPath
        self.relayEndpoint = relayEndpoint
        self.clawStaticPublicKey = clawStaticPublicKey
        self.notAfter = notAfter
        self.authz = authz
        self.appPresentation = appPresentation
    }

    public var audience: RelayStreamAudience {
        authz ?? .device
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue)
    }

    fileprivate var cborValue: HouseholdCBORValue {
        var fields: [String: HouseholdCBORValue] = [
            "claw_id": .text(clawId),
            "claw_static_pub": .bytes(clawStaticPublicKey),
            "expected_path": .text(expectedPath.rawValue),
            "guest_device_pub": .bytes(guestDevicePublicKey),
            "kind": .text(kind),
            "not_after": .unsigned(notAfter),
            "relay_endpoint": .text(relayEndpoint),
            "rendezvous_token": .bytes(rendezvousToken),
            "resource": .text(resource.rawValue),
            "slot_id": .bytes(slotId),
            "v": .unsigned(UInt64(v)),
        ]
        if let authz {
            fields["authz"] = authz.cborValue
        }
        if let appPresentation {
            fields["app_presentation"] = appPresentation.cborValue
        }
        return .map(fields)
    }

    fileprivate static func decode(_ value: HouseholdCBORValue?) throws -> RelayStreamOfferPayload {
        let map = try RelayStreamOfferContract.expectMap(value)
        let requiredKeys: Set<String> = [
            "claw_id",
            "claw_static_pub",
            "expected_path",
            "guest_device_pub",
            "kind",
            "not_after",
            "relay_endpoint",
            "rendezvous_token",
            "resource",
            "slot_id",
            "v",
        ]
        let allowedKeys = requiredKeys.union(["authz", "app_presentation"])
        guard Set(map.keys).isSubset(of: allowedKeys),
              requiredKeys.isSubset(of: Set(map.keys))
        else {
            throw RelayStreamOfferError.malformed
        }
        let resourceRaw = try RelayStreamOfferContract.expectText(map["resource"])
        let pathRaw = try RelayStreamOfferContract.expectText(map["expected_path"])
        guard let resource = RelayStreamResource(rawValue: resourceRaw),
              let expectedPath = RelayStreamExpectedPath(rawValue: pathRaw)
        else {
            throw RelayStreamOfferError.malformed
        }
        let authz: RelayStreamAudience?
        switch map["authz"] {
        case .none:
            authz = nil
        case .some(let value):
            authz = try RelayStreamAudience.decode(value)
        }
        let appPresentation: ShareableAppPresentation?
        switch map["app_presentation"] {
        case .none:
            appPresentation = nil
        case .some(let value):
            appPresentation = try ShareableAppPresentation.decode(value)
        }
        return RelayStreamOfferPayload(
            v: try RelayStreamOfferContract.expectUInt8(map["v"]),
            kind: try RelayStreamOfferContract.expectText(map["kind"]),
            rendezvousToken: try RelayStreamOfferContract.expectBytes(map["rendezvous_token"]),
            clawId: try RelayStreamOfferContract.expectText(map["claw_id"]),
            slotId: try RelayStreamOfferContract.expectBytes(map["slot_id"]),
            guestDevicePublicKey: try RelayStreamOfferContract.expectBytes(map["guest_device_pub"]),
            resource: resource,
            expectedPath: expectedPath,
            relayEndpoint: try RelayStreamOfferContract.expectText(map["relay_endpoint"]),
            clawStaticPublicKey: try RelayStreamOfferContract.expectBytes(map["claw_static_pub"]),
            notAfter: try RelayStreamOfferContract.expectUInt64(map["not_after"]),
            authz: authz,
            appPresentation: appPresentation
        )
    }
}

extension RelayStreamAudience {
    fileprivate var cborValue: HouseholdCBORValue {
        switch self {
        case .device:
            return .text("device")
        case .group(let groupId, let memberId):
            return .map([
                "group": .map([
                    "group_id": .text(groupId),
                    "member_id": .text(memberId),
                ]),
            ])
        case .public:
            return .text("public")
        }
    }

    fileprivate static func decode(_ value: HouseholdCBORValue) throws -> RelayStreamAudience {
        switch value {
        case .text("device"):
            return .device
        case .text("public"):
            return .public
        case .map(let outer):
            guard outer.count == 1,
                  let groupValue = outer["group"],
                  case .map(let groupMap) = groupValue
            else {
                throw RelayStreamOfferError.malformed
            }
            guard Set(groupMap.keys) == ["group_id", "member_id"] else {
                throw RelayStreamOfferError.malformed
            }
            return .group(
                groupId: try RelayStreamOfferContract.expectText(groupMap["group_id"]),
                memberId: try RelayStreamOfferContract.expectText(groupMap["member_id"])
            )
        default:
            throw RelayStreamOfferError.malformed
        }
    }
}

public struct RelayStreamOfferContract: Sendable, Equatable {
    public let payload: RelayStreamOfferPayload
    public let signerPublicKey: Data
    public let signature: Data

    public init(payload: RelayStreamOfferPayload, signerPublicKey: Data, signature: Data) {
        self.payload = payload
        self.signerPublicKey = signerPublicKey
        self.signature = signature
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(.map([
            "payload": payload.cborValue,
            "signature": .bytes(signature),
            "signer_pub": .bytes(signerPublicKey),
        ]))
    }

    public static func fromCanonicalBytes(_ bytes: Data) throws -> RelayStreamOfferContract {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(bytes)
        } catch {
            throw RelayStreamOfferError.malformed
        }
        let map = try expectMap(value)
        guard Set(map.keys) == ["payload", "signature", "signer_pub"] else {
            throw RelayStreamOfferError.malformed
        }
        return RelayStreamOfferContract(
            payload: try RelayStreamOfferPayload.decode(map["payload"]),
            signerPublicKey: try expectBytes(map["signer_pub"]),
            signature: try expectBytes(map["signature"])
        )
    }

    public func verifyOwnerSignature(
        expectedSignerPublicKey: Data,
        nowUnix: UInt64
    ) throws {
        try validatePayload(nowUnix: nowUnix)
        guard signerPublicKey == expectedSignerPublicKey else {
            throw RelayStreamOfferError.signerMismatch
        }
        guard expectedSignerPublicKey.count == 33, signature.count == 64 else {
            throw RelayStreamOfferError.malformed
        }
        let publicKey: P256.Signing.PublicKey
        let parsedSignature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(compressedRepresentation: expectedSignerPublicKey)
            parsedSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        } catch {
            throw RelayStreamOfferError.malformed
        }
        guard publicKey.isValidSignature(parsedSignature, for: payload.canonicalBytes()) else {
            throw RelayStreamOfferError.signatureRejected
        }
    }

    public func verifyForAudience(
        expectedSignerPublicKey: Data,
        expectedGuestDevicePublicKey: Data,
        nowUnix: UInt64
    ) throws {
        try verifyOwnerSignature(expectedSignerPublicKey: expectedSignerPublicKey, nowUnix: nowUnix)
        guard payload.guestDevicePublicKey == expectedGuestDevicePublicKey else {
            throw RelayStreamOfferError.audienceMismatch
        }
    }

    /// Verify an offer is well-formed, owner-signed, addressed to this guest,
    /// and carries a resource this caller is prepared to terminate.
    ///
    /// `allowedResources` is the caller's declaration of intent, not a
    /// formality. A consumer that binds the byte stream to a specific
    /// surface — a terminal emulator, a `WKWebView` — must pass the single
    /// resource it handles, so a PTY consumer can never be handed a ClawSite
    /// stream (or vice versa) even though both are owner-signed and both ride
    /// the same framing. Only a layer that genuinely does not yet know the
    /// consumer (the claim submitter, which just validates whatever the owner
    /// returned) should take the default.
    ///
    /// `ipTunnel` is excluded from the default on purpose: it has its own
    /// stricter entry point, `verifyRelayStreamIPTunnelGuest`, which also
    /// demands a Group audience. Reaching it through here would skip that.
    public func verifyRelayStreamGuest(
        expectedSignerPublicKey: Data,
        expectedGuestDevicePublicKey: Data,
        nowUnix: UInt64,
        allowedResources: Set<RelayStreamResource> = RelayStreamResource.guestSupported
    ) throws {
        try verifyForAudience(
            expectedSignerPublicKey: expectedSignerPublicKey,
            expectedGuestDevicePublicKey: expectedGuestDevicePublicKey,
            nowUnix: nowUnix
        )
        guard payload.expectedPath == .relayStream else {
            throw RelayStreamOfferError.expectedPathMismatch
        }
        guard allowedResources.contains(payload.resource) else {
            throw RelayStreamOfferError.resourceMismatch
        }
        _ = try relayEndpointURL()
    }

    /// Verifies the owner-signed, guest-bound Group offer required by the
    /// packet-tunnel extension.
    ///
    /// Device and Public audiences remain ineligible here. The production
    /// control plane must have granted the member and claw before issuing the
    /// Group offer; the extension then pins that exact signed offer.
    public func verifyRelayStreamIPTunnelGuest(
        expectedSignerPublicKey: Data,
        expectedGuestDevicePublicKey: Data,
        nowUnix: UInt64
    ) throws {
        try verifyForAudience(
            expectedSignerPublicKey: expectedSignerPublicKey,
            expectedGuestDevicePublicKey: expectedGuestDevicePublicKey,
            nowUnix: nowUnix
        )
        guard payload.expectedPath == .relayStream else {
            throw RelayStreamOfferError.expectedPathMismatch
        }
        guard payload.resource == .ipTunnel else {
            throw RelayStreamOfferError.resourceMismatch
        }
        guard case .group = payload.audience else {
            throw RelayStreamOfferError.audienceMismatch
        }
        _ = try relayEndpointURL()
    }

    public func verifyRelayStreamGuest(
        credential: GuestCredential,
        nowUnix: UInt64,
        allowedResources: Set<RelayStreamResource> = RelayStreamResource.guestSupported
    ) throws {
        try verifyRelayStreamGuest(
            expectedSignerPublicKey: credential.ownerPublicKey,
            expectedGuestDevicePublicKey: credential.guestDevicePublicKey,
            nowUnix: nowUnix,
            allowedResources: allowedResources
        )
        guard payload.clawId == credential.clawId else {
            throw RelayStreamOfferError.credentialClawMismatch
        }
        guard payload.slotId == credential.slotId else {
            throw RelayStreamOfferError.credentialSlotMismatch
        }
        guard payload.notAfter <= credential.expiresAt else {
            throw RelayStreamOfferError.credentialExpiryExceeded
        }
    }

    public func relayEndpointURL() throws -> URL {
        guard let url = URL(string: payload.relayEndpoint),
              url.scheme == "relay-stream",
              let host = url.host,
              !host.isEmpty,
              url.port != nil
        else {
            throw RelayStreamOfferError.invalidRelayEndpoint
        }
        return url
    }

    private func validatePayload(nowUnix: UInt64) throws {
        guard payload.v == RelayStreamOfferPayload.currentVersion else {
            throw RelayStreamOfferError.unsupportedVersion(payload.v)
        }
        guard payload.kind == RelayStreamOfferPayload.kind else {
            throw RelayStreamOfferError.kindMismatch
        }
        guard payload.notAfter > nowUnix else {
            throw RelayStreamOfferError.expired
        }
        guard payload.rendezvousToken.count >= 16,
              payload.rendezvousToken.count <= 128,
              payload.slotId.count == 16,
              payload.guestDevicePublicKey.count == 33,
              payload.clawStaticPublicKey.count == 32
        else {
            throw RelayStreamOfferError.malformed
        }
        if let presentation = payload.appPresentation {
            // Shape is re-validated here rather than trusted from decode —
            // `ShareableAppPresentation.decode(_:)` deliberately skips it
            // (see that type's doc comment).
            try presentation.validateShape()
            // Namespace fence: the signed snapshot may exist ONLY on the
            // Device+ClawSite path it was designed for.
            guard payload.audience == .device, payload.resource == .clawSite else {
                throw RelayStreamOfferError.invalidPresentation("audience-resource")
            }
            // Coherence fence: a signature over two contradictory identities
            // is still a contradiction.
            guard presentation.appId == payload.clawId else {
                throw RelayStreamOfferError.invalidPresentation("app_id-claw-mismatch")
            }
        }
    }
}

public enum RelayStreamOfferError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion(UInt8)
    case kindMismatch
    case expired
    case signerMismatch
    case signatureRejected
    case audienceMismatch
    case expectedPathMismatch
    case resourceMismatch
    case credentialClawMismatch
    case credentialSlotMismatch
    case credentialExpiryExceeded
    case invalidRelayEndpoint
    /// Mirrors Rust `RelayStreamContractError::InvalidPresentation(&'static str)`
    /// — the associated string is the same reason tag Rust uses:
    /// `"app_id"`, `"display_name"`, `"owner_display_name"`,
    /// `"audience-resource"`, `"app_id-claw-mismatch"`.
    case invalidPresentation(String)
}

extension RelayStreamOfferContract {
    fileprivate static func expectMap(_ value: HouseholdCBORValue?) throws -> [String: HouseholdCBORValue] {
        guard case .some(.map(let map)) = value else { throw RelayStreamOfferError.malformed }
        return map
    }

    fileprivate static func expectText(_ value: HouseholdCBORValue?) throws -> String {
        guard case .some(.text(let text)) = value else { throw RelayStreamOfferError.malformed }
        return text
    }

    fileprivate static func expectBytes(_ value: HouseholdCBORValue?) throws -> Data {
        guard case .some(.bytes(let bytes)) = value else { throw RelayStreamOfferError.malformed }
        return bytes
    }

    fileprivate static func expectUInt8(_ value: HouseholdCBORValue?) throws -> UInt8 {
        guard case .some(.unsigned(let number)) = value, number <= UInt64(UInt8.max) else {
            throw RelayStreamOfferError.malformed
        }
        return UInt8(number)
    }

    fileprivate static func expectUInt64(_ value: HouseholdCBORValue?) throws -> UInt64 {
        guard case .some(.unsigned(let number)) = value else { throw RelayStreamOfferError.malformed }
        return number
    }
}
