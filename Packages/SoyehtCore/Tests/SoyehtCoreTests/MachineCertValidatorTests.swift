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

    @Test func issuedByPrefixedFormAccepted() throws {
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

