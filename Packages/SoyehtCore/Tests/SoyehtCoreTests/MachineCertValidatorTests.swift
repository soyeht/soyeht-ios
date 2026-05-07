import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("MachineCertValidator")
struct MachineCertValidatorTests {
    private static let now = Date(timeIntervalSince1970: 1_715_000_000)

    private static func householdKey(seed: UInt8 = 0x11) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    }

    private static func machinePublicKey(seed: UInt8 = 0x22) -> Data {
        HouseholdTestFixtures.publicKey(byte: seed)
    }

    @Test func decodeAndValidateValidCert() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)

        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now.addingTimeInterval(-30)
        )
        let cert = try MachineCert(cbor: cbor)

        #expect(cert.householdId == hhId)
        #expect(cert.machinePublicKey == mPub)
        #expect(cert.platform == .macos)
        #expect(cert.signature.count == 64)

        try MachineCertValidator.validate(
            cert: cert,
            expectedHouseholdId: hhId,
            householdPublicKey: hhPub,
            isRevoked: { _ in false },
            now: Self.now
        )
    }

    @Test func tamperedHostnameInvalidatesSignature() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)

        // Sign normally then mutate raw CBOR by re-encoding with a different hostname.
        let original = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now
        )
        guard case .map(var map) = try HouseholdCBOR.decode(original) else {
            Issue.record("expected map")
            return
        }
        map["hostname"] = .text("attacker.example")
        let tampered = HouseholdCBOR.encode(.map(map))
        let cert = try MachineCert(cbor: tampered)

        do {
            try MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: hhId,
                householdPublicKey: hhPub,
                isRevoked: { _ in false },
                now: Self.now
            )
            Issue.record("Expected invalidSignature")
        } catch MachineCertError.invalidSignature {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func wrongIssuerRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)

        // Sign with householdPrivateKey but with a different `issued_by`.
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now,
            overrides: ["issued_by": .text("hh_someoneelse")]
        )
        let cert = try MachineCert(cbor: cbor)

        do {
            try MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: hhId,
                householdPublicKey: hhPub,
                isRevoked: { _ in false },
                now: Self.now
            )
            Issue.record("Expected invalidIssuer")
        } catch MachineCertError.invalidIssuer {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func wrongHouseholdRejected() throws {
        let hh = try Self.householdKey()
        let foreignHh = try Self.householdKey(seed: 0x99)
        let mPub = Self.machinePublicKey()
        let foreignHhId = try HouseholdIdentifiers.householdIdentifier(for: foreignHh.publicKey.compressedRepresentation)

        // Cert claims to belong to foreign household, but we validate against ours.
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: foreignHh,
            machinePublicKey: mPub,
            joinedAt: Self.now
        )
        let cert = try MachineCert(cbor: cbor)
        let localHhId = try HouseholdIdentifiers.householdIdentifier(for: hh.publicKey.compressedRepresentation)

        #expect(cert.householdId == foreignHhId)
        #expect(cert.householdId != localHhId)

        do {
            try MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: localHhId,
                householdPublicKey: hh.publicKey.compressedRepresentation,
                isRevoked: { _ in false },
                now: Self.now
            )
            Issue.record("Expected householdMismatch")
        } catch MachineCertError.householdMismatch {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func crlListedRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)

        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now
        )
        let cert = try MachineCert(cbor: cbor)

        do {
            try MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: hhId,
                householdPublicKey: hhPub,
                isRevoked: { id in id == cert.machineId },
                now: Self.now
            )
            Issue.record("Expected revoked")
        } catch MachineCertError.revoked {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func futureJoinedAtRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now.addingTimeInterval(120) // 2 minutes ahead, > 60s tolerance
        )
        let cert = try MachineCert(cbor: cbor)

        do {
            try MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: hhId,
                householdPublicKey: hhPub,
                isRevoked: { _ in false },
                now: Self.now
            )
            Issue.record("Expected invalidJoinedAt")
        } catch MachineCertError.invalidJoinedAt {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func machineIdMismatchRejectedAtDecode() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now,
            overrides: ["m_id": .text("m_attacker")]
        )

        do {
            _ = try MachineCert(cbor: cbor)
            Issue.record("Expected machineIdMismatch")
        } catch MachineCertError.machineIdMismatch {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func unsupportedPlatformRejectedAtDecode() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now,
            overrides: ["platform": .text("freebsd")]
        )

        do {
            _ = try MachineCert(cbor: cbor)
            Issue.record("Expected unsupportedPlatform")
        } catch MachineCertError.unsupportedPlatform {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func wrongTypeRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now,
            overrides: ["type": .text("person")]
        )

        do {
            _ = try MachineCert(cbor: cbor)
            Issue.record("Expected wrongType")
        } catch MachineCertError.wrongType {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    /// §5: `issued_by` MUST be exactly `hh_id` for a `MachineCert` (only
    /// the household root signs machines). Accepting the `hh:<id>` alias
    /// would create certs theyos never emits — strict equality only.
    @Test func issuedByPrefixedFormRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)

        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now,
            overrides: ["issued_by": .text("hh:\(hhId)")]
        )
        let cert = try MachineCert(cbor: cbor)

        do {
            try MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: hhId,
                householdPublicKey: hhPub,
                isRevoked: { _ in false },
                now: Self.now
            )
            Issue.record("Expected invalidIssuer for hh: alias")
        } catch MachineCertError.invalidIssuer {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    /// Anti-forge guard: a CBOR map encoded with non-canonical key order
    /// (alphabetical instead of length-first byte-lex per RFC 8949 §4.2.1)
    /// would otherwise pass signature verification because
    /// `verifySignature` re-canonicalizes the same map. The decoder MUST
    /// reject the cert before signature verification ever runs.
    @Test func nonCanonicalKeyOrderRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()

        // Build the canonical bytes via the fixture, then re-emit the same
        // semantic map with alphabetical key order. Any byte difference
        // proves non-canonical input MUST be rejected.
        let canonical = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now
        )
        guard case .map(let map) = try HouseholdCBOR.decode(canonical) else {
            Issue.record("expected map")
            return
        }
        // Alphabetical order via OrderedAlphabeticalCBOR helper below.
        let alphabetical = encodeMapAlphabetically(map)
        // Sanity: the two byte streams must differ (otherwise the test is moot).
        #expect(alphabetical != canonical)

        do {
            _ = try MachineCert(cbor: alphabetical)
            Issue.record("Expected nonCanonicalEncoding")
        } catch MachineCertError.nonCanonicalEncoding {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func emptyHostnameRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            hostname: "",
            joinedAt: Self.now
        )

        do {
            _ = try MachineCert(cbor: cbor)
            Issue.record("Expected invalidHostname for empty hostname")
        } catch MachineCertError.invalidHostname {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func oversizeHostnameRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        // 65 ASCII bytes = 65 UTF-8 bytes, one over the limit of 64.
        let oversize = String(repeating: "a", count: 65)
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            hostname: oversize,
            joinedAt: Self.now
        )

        do {
            _ = try MachineCert(cbor: cbor)
            Issue.record("Expected invalidHostname for >64 bytes")
        } catch MachineCertError.invalidHostname {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func maxLengthHostnameAccepted() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let exact = String(repeating: "h", count: 64)  // exactly the upper bound
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            hostname: exact,
            joinedAt: Self.now
        )
        let cert = try MachineCert(cbor: cbor)
        #expect(cert.hostname == exact)
    }

    /// `v` is a CBOR `unsigned` (UInt64). A peer-supplied value that
    /// exceeds `Int.max` must surface as a typed `unsupportedVersion`
    /// error, NOT trap the process via `Int(_:UInt64)` (the trapping
    /// initializer).
    @Test func versionOverflowRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now,
            overrides: ["v": .unsigned(UInt64.max)]
        )

        do {
            _ = try MachineCert(cbor: cbor)
            Issue.record("Expected unsupportedVersion (no trap)")
        } catch MachineCertError.unsupportedVersion {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    /// `joined_at` is also UInt64 on the wire. A peer-supplied value that
    /// exceeds `Int64.max` must surface as `invalidJoinedAt`, not trap.
    @Test func joinedAtOverflowRejected() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now,
            overrides: ["joined_at": .unsigned(UInt64.max)]
        )

        do {
            _ = try MachineCert(cbor: cbor)
            Issue.record("Expected invalidJoinedAt (no trap)")
        } catch MachineCertError.invalidJoinedAt {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    // Replaces the previous unused fixture so the suite only contains
    // tests that currently apply post-strict-issued-by.
    @Test func issuedByExactMatchAccepted() throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)

        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now
        )
        let cert = try MachineCert(cbor: cbor)
        #expect(cert.issuedBy == hhId)

        try MachineCertValidator.validate(
            cert: cert,
            expectedHouseholdId: hhId,
            householdPublicKey: hhPub,
            isRevoked: { _ in false },
            now: Self.now
        )
    }

    @Test func crlStoreIntegration() async throws {
        let hh = try Self.householdKey()
        let mPub = Self.machinePublicKey()
        let hhPub = hh.publicKey.compressedRepresentation
        let hhId = try HouseholdIdentifiers.householdIdentifier(for: hhPub)
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            joinedAt: Self.now
        )
        let cert = try MachineCert(cbor: cbor)
        let crl = try CRLStore(storage: InMemoryHouseholdStorage(), account: "test.crl")

        // Pre-revocation: passes.
        try await MachineCertValidator.validate(
            cert: cert,
            expectedHouseholdId: hhId,
            householdPublicKey: hhPub,
            crl: crl,
            now: Self.now
        )

        // Add to CRL → revoked.
        _ = try await crl.append(
            RevocationEntry(
                subjectId: cert.machineId,
                revokedAt: Self.now,
                reason: "test",
                cascade: .selfOnly,
                signature: Data(repeating: 0xAA, count: 64)
            )
        )

        do {
            try await MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: hhId,
                householdPublicKey: hhPub,
                crl: crl,
                now: Self.now
            )
            Issue.record("Expected revoked")
        } catch MachineCertError.revoked {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}

/// Hand-rolled CBOR map encoder that emits keys in alphabetical (NOT
/// length-first byte-lex) order, used to construct adversarial fixtures
/// for the canonical-encoding rejection test. Production code MUST never
/// use this — it intentionally violates RFC 8949 §4.2.1.
private func encodeMapAlphabetically(_ map: [String: HouseholdCBORValue]) -> Data {
    var data = Data()
    appendCBORTypeArgument(major: 5, value: UInt64(map.count), to: &data)
    let alphabeticalKeys = map.keys.sorted()
    for key in alphabeticalKeys {
        appendCBORValue(.text(key), to: &data)
        appendCBORValue(map[key]!, to: &data)
    }
    return data
}

private func appendCBORValue(_ value: HouseholdCBORValue, to data: inout Data) {
    // Recursive encoder mirroring HouseholdCBOR.encode but for the inner
    // values. For nested maps we still emit canonical (length-first) order
    // — only the outer map's key order is intentionally alphabetical, so
    // the canonical-roundtrip check fails on the outer level.
    switch value {
    case .map:
        // No nested maps appear in MachineCert fixtures; falling back to
        // the canonical encoder keeps this helper minimal.
        data.append(HouseholdCBOR.encode(value))
    case .array:
        data.append(HouseholdCBOR.encode(value))
    case .unsigned, .negative, .bytes, .text, .bool, .null:
        data.append(HouseholdCBOR.encode(value))
    }
}

private func appendCBORTypeArgument(major: UInt8, value: UInt64, to data: inout Data) {
    let prefix = major << 5
    if value < 24 {
        data.append(prefix | UInt8(value))
    } else if value <= UInt64(UInt8.max) {
        data.append(prefix | 24)
        data.append(UInt8(value))
    } else if value <= UInt64(UInt16.max) {
        data.append(prefix | 25)
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    } else if value <= UInt64(UInt32.max) {
        data.append(prefix | 26)
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    } else {
        data.append(prefix | 27)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
