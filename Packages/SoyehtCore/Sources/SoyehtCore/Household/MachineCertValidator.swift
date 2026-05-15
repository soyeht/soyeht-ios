import CryptoKit
import Foundation

public enum MachineCertError: Error, Equatable, Sendable {
    case malformed
    case nonCanonicalEncoding
    case unknownFields(Set<String>)
    case unsupportedVersion
    case wrongType
    case invalidMachinePublicKey
    case machineIdMismatch
    case householdMismatch
    case invalidIssuer
    case unsupportedPlatform
    case invalidHostname
    case invalidSignatureLength
    case invalidSignature
    case revoked
    case invalidJoinedAt
}

public struct MachineCert: Equatable, Sendable {
    public enum Platform: String, Sendable, Equatable {
        case macos
        case linuxNix = "linux-nix"
        case linuxOther = "linux-other"
    }

    /// Protocol-defined inclusive bounds for the `hostname` field per
    /// `theyos/docs/household-protocol.md` §5: 1..64 UTF-8 bytes.
    public static let minHostnameByteLength = 1
    public static let maxHostnameByteLength = 64

    /// The closed set of map keys defined by §5 for a v1 `MachineCert`.
    /// Theyos uses `deny_unknown_fields` for this type — accepting any
    /// extra signed key here would let two peers diverge on what the cert
    /// "means" (the iPhone ignores it, theyos rejects, or vice versa),
    /// which is a split-brain risk worth a typed error.
    ///
    /// `caveats` is emitted by theyos and is reserved for later delegation
    /// work. In this phase it must be present as `[]` or omitted by legacy
    /// fixtures; any non-empty value is rejected below.
    static let expectedKeys: Set<String> = [
        "v",
        "type",
        "hh_id",
        "m_id",
        "m_pub",
        "hostname",
        "platform",
        "joined_at",
        "issued_by",
        "caveats",
        "signature",
    ]

    public let rawCBOR: Data
    public let version: Int
    public let type: String
    public let householdId: String
    public let machineId: String
    public let machinePublicKey: Data
    public let hostname: String
    public let platform: Platform
    public let joinedAt: Date
    public let issuedBy: String
    public let signature: Data

    public init(cbor: Data) throws {
        guard case .map(let map) = try HouseholdCBOR.decode(cbor) else {
            throw MachineCertError.malformed
        }
        // Phase-3 wire invariant: every `MachineCert` MUST be in canonical
        // CBOR form (RFC 8949 §4.2.1, length-first byte-lex map sort) so
        // the signing-bytes are bit-identical across implementations.
        // Re-encoding the decoded map and byte-comparing is the cheapest
        // way to enforce this without re-implementing the canon rules
        // here. A non-canonical-but-semantically-equivalent CBOR that the
        // signer did NOT actually sign would otherwise pass signature
        // verification (since `verifySignature` strips and re-canonicalizes
        // the same map), opening a forge surface.
        guard HouseholdCBOR.encode(.map(map)) == cbor else {
            throw MachineCertError.nonCanonicalEncoding
        }

        // §5 fixes the MachineCert shape; any extra key would be a signed
        // field the iPhone silently ignores while the (theyos)
        // `deny_unknown_fields` issuer-side validator would reject. Catch
        // the divergence at the decode boundary instead of letting it
        // silently propagate through validation.
        let extraKeys = Set(map.keys).subtracting(Self.expectedKeys)
        guard extraKeys.isEmpty else {
            throw MachineCertError.unknownFields(extraKeys)
        }
        if let caveatsValue = map["caveats"] {
            guard case .array(let caveats) = caveatsValue, caveats.isEmpty else {
                throw MachineCertError.malformed
            }
        }

        self.rawCBOR = cbor

        // CBOR `v` is an unbounded UInt64 on the wire. `Int(exactly:)`
        // surfaces overflow as a typed `unsupportedVersion` error instead
        // of trapping the process — peers send untrusted bytes.
        let versionRaw = try map.requiredUInt("v")
        guard let version = Int(exactly: versionRaw) else {
            throw MachineCertError.unsupportedVersion
        }
        self.version = version

        self.type = try map.requiredText("type")
        self.householdId = try map.requiredText("hh_id")
        self.machineId = try map.requiredText("m_id")
        self.machinePublicKey = try map.requiredBytes("m_pub")

        let hostname = try map.requiredText("hostname")
        let hostnameByteCount = hostname.utf8.count
        guard hostnameByteCount >= Self.minHostnameByteLength,
              hostnameByteCount <= Self.maxHostnameByteLength else {
            throw MachineCertError.invalidHostname
        }
        self.hostname = hostname

        let platformText = try map.requiredText("platform")
        guard let platform = Platform(rawValue: platformText) else {
            throw MachineCertError.unsupportedPlatform
        }
        self.platform = platform

        // `joined_at` is a UInt64 epoch-seconds field per §5; the cast to
        // `Int64` cannot overflow because `Date(timeIntervalSince1970:)`
        // accepts any finite Double (~10²² range), but we still go through
        // `Int(exactly:)` defensively to keep the trap surface zero.
        let joinedAtRaw = try map.requiredUInt("joined_at")
        guard let joinedAtSeconds = Int64(exactly: joinedAtRaw) else {
            throw MachineCertError.invalidJoinedAt
        }
        self.joinedAt = Date(timeIntervalSince1970: TimeInterval(joinedAtSeconds))

        self.issuedBy = try map.requiredText("issued_by")
        self.signature = try map.requiredBytes("signature")

        guard version == 1 else { throw MachineCertError.unsupportedVersion }
        guard type == "machine" else { throw MachineCertError.wrongType }
        guard signature.count == 64 else { throw MachineCertError.invalidSignatureLength }
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(machinePublicKey)
        } catch {
            throw MachineCertError.invalidMachinePublicKey
        }
        let derivedMachineId = try HouseholdIdentifiers.identifier(for: machinePublicKey, kind: .machine)
        guard derivedMachineId == machineId else {
            throw MachineCertError.machineIdMismatch
        }
    }
}

/// Validates a `MachineCert` against the local household's root key plus the
/// CRL. Stateless — the validator does not own any storage; callers pass
/// their `CRLStore` snapshot or per-call check.
///
/// **No protocol-level expiry.** §5 of `household-protocol.md` defines
/// `MachineCert` with only `joined_at` (no `not_after`). Trust is gated
/// purely by CRL membership (§9), not cert age. `clockSkewTolerance` is a
/// one-sided guard against future-dated certs caused by clock skew, NOT a
/// freshness check — a cert minted years ago is still valid until revoked.
/// If a future protocol revision adds an expiry field, validate it here.
public enum MachineCertValidator {
    public static func validate(
        cert: MachineCert,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        isRevoked: (String) -> Bool,
        now: Date = Date(),
        clockSkewTolerance: TimeInterval = 60
    ) throws {
        guard cert.householdId == expectedHouseholdId else {
            throw MachineCertError.householdMismatch
        }
        // §5: "issued_by: text // hh_id (always)". No `hh:` alias is
        // permitted here — accepting one would create certs the iPhone
        // honors but theyos never emits, drifting cross-repo invariants.
        guard cert.issuedBy == expectedHouseholdId else {
            throw MachineCertError.invalidIssuer
        }
        guard cert.joinedAt.timeIntervalSince(now) <= clockSkewTolerance else {
            throw MachineCertError.invalidJoinedAt
        }
        try verifySignature(cert: cert, householdPublicKey: householdPublicKey)
        if isRevoked(cert.machineId) {
            throw MachineCertError.revoked
        }
    }

    public static func validate(
        cert: MachineCert,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        crl: CRLStore,
        now: Date = Date(),
        clockSkewTolerance: TimeInterval = 60
    ) async throws {
        let revoked = await crl.contains(cert.machineId)
        try validate(
            cert: cert,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey,
            isRevoked: { _ in revoked },
            now: now,
            clockSkewTolerance: clockSkewTolerance
        )
    }

    private static func verifySignature(cert: MachineCert, householdPublicKey: Data) throws {
        let signingBytes: Data
        do {
            signingBytes = try HouseholdCBOR.canonicalMapWithoutKey(cert.rawCBOR, removing: "signature")
        } catch {
            throw MachineCertError.invalidSignature
        }
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: householdPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: cert.signature)
            guard key.isValidSignature(signature, for: signingBytes) else {
                throw MachineCertError.invalidSignature
            }
        } catch let error as MachineCertError {
            throw error
        } catch {
            throw MachineCertError.invalidSignature
        }
    }
}

private extension Dictionary where Key == String, Value == HouseholdCBORValue {
    func requiredText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else { throw MachineCertError.malformed }
        return value
    }

    func requiredBytes(_ key: String) throws -> Data {
        guard case .bytes(let value) = self[key] else { throw MachineCertError.malformed }
        return value
    }

    func requiredUInt(_ key: String) throws -> UInt64 {
        guard case .unsigned(let value) = self[key] else { throw MachineCertError.malformed }
        return value
    }
}
