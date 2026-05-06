import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("OperatorAuthorizationSigner")
struct OperatorAuthorizationSignerTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let householdId = "hh_test"

    private static func ownerKey(seed: UInt8 = 0x33) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    }

    private static func ownerIdentity(
        signing privateKey: P256.Signing.PrivateKey,
        signer: (@Sendable (Data) throws -> Data)? = nil
    ) throws -> any OwnerIdentitySigning {
        try InMemoryOwnerIdentityKey(
            publicKey: privateKey.publicKey.compressedRepresentation,
            keyReference: "test-owner-key",
            signer: signer ?? { try privateKey.signature(for: $0).rawRepresentation }
        )
    }

    private static func envelope(householdId: String = Self.householdId) -> JoinRequestEnvelope {
        JoinRequestEnvelope(
            householdId: householdId,
            machinePublicKey: Data([0x02] + [UInt8](repeating: 0xAA, count: 32)),
            nonce: Data(repeating: 0xBB, count: 32),
            rawHostname: "studio.local",
            rawPlatform: "macos",
            candidateAddress: "100.64.1.5:8443",
            ttlUnix: UInt64(now.addingTimeInterval(300).timeIntervalSince1970),
            challengeSignature: Data(repeating: 0xCC, count: 64),
            transportOrigin: .qrTailscale,
            receivedAt: now
        )
    }

    @Test func signProducesByteIdenticalCanonicalContextAndOuterBody() throws {
        let privateKey = try Self.ownerKey()
        let owner = try Self.ownerIdentity(signing: privateKey)
        let signer = OperatorAuthorizationSigner()
        let env = Self.envelope()

        let result = try signer.sign(
            envelope: env,
            cursor: 99,
            ownerIdentity: owner,
            localHouseholdId: Self.householdId,
            now: Self.now
        )

        // Signed context MUST exactly match what HouseholdCBOR produces for these inputs.
        let expectedContext = HouseholdCBOR.ownerApprovalContext(
            householdId: env.householdId,
            ownerPersonId: owner.personId,
            cursor: 99,
            challengeSignature: env.challengeSignature,
            timestamp: UInt64(Self.now.timeIntervalSince1970)
        )
        #expect(result.signedContext == expectedContext)

        // Outer body MUST exactly match HouseholdCBOR's canonical wire form.
        let expectedBody = HouseholdCBOR.ownerApprovalBody(
            cursor: 99,
            approvalSignature: result.approvalSignature
        )
        #expect(result.outerBody == expectedBody)
        #expect(result.cursor == 99)
        #expect(result.timestamp == UInt64(Self.now.timeIntervalSince1970))
        #expect(result.approvalSignature.count == 64)
    }

    @Test func producedSignatureVerifiesUnderOwnerPublicKey() throws {
        let privateKey = try Self.ownerKey()
        let owner = try Self.ownerIdentity(signing: privateKey)
        let signer = OperatorAuthorizationSigner()

        let result = try signer.sign(
            envelope: Self.envelope(),
            cursor: 1,
            ownerIdentity: owner,
            localHouseholdId: Self.householdId,
            now: Self.now
        )

        let publicKey = privateKey.publicKey
        let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: result.approvalSignature)
        #expect(publicKey.isValidSignature(ecdsaSignature, for: result.signedContext))
    }

    @Test func biometryCancelSurfacesTypedError() throws {
        let privateKey = try Self.ownerKey()
        let owner = try Self.ownerIdentity(signing: privateKey, signer: { _ in
            throw OwnerIdentityKeyError.biometryCanceled
        })
        let signer = OperatorAuthorizationSigner()

        do {
            _ = try signer.sign(
                envelope: Self.envelope(),
                cursor: 1,
                ownerIdentity: owner,
                localHouseholdId: Self.householdId,
                now: Self.now
            )
            Issue.record("Expected biometryCanceled")
        } catch OperatorAuthorizationSignerError.biometryCanceled {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func biometryLockoutSurfacesTypedError() throws {
        let privateKey = try Self.ownerKey()
        let owner = try Self.ownerIdentity(signing: privateKey, signer: { _ in
            throw OwnerIdentityKeyError.biometryLockout
        })
        let signer = OperatorAuthorizationSigner()

        do {
            _ = try signer.sign(
                envelope: Self.envelope(),
                cursor: 1,
                ownerIdentity: owner,
                localHouseholdId: Self.householdId,
                now: Self.now
            )
            Issue.record("Expected biometryLockout")
        } catch OperatorAuthorizationSignerError.biometryLockout {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func underlyingSigningErrorMapsToSigningFailed() throws {
        struct StubError: Error {}
        let privateKey = try Self.ownerKey()
        let owner = try Self.ownerIdentity(signing: privateKey, signer: { _ in throw StubError() })
        let signer = OperatorAuthorizationSigner()

        do {
            _ = try signer.sign(
                envelope: Self.envelope(),
                cursor: 1,
                ownerIdentity: owner,
                localHouseholdId: Self.householdId,
                now: Self.now
            )
            Issue.record("Expected signingFailed")
        } catch OperatorAuthorizationSignerError.signingFailed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func householdMismatchRefusesToInvokeSigner() throws {
        var signerCalled = false
        let privateKey = try Self.ownerKey()
        let owner = try Self.ownerIdentity(signing: privateKey, signer: { _ in
            signerCalled = true
            return Data(repeating: 0, count: 64)
        })
        let signer = OperatorAuthorizationSigner()
        let foreignEnvelope = Self.envelope(householdId: "hh_other")

        do {
            _ = try signer.sign(
                envelope: foreignEnvelope,
                cursor: 1,
                ownerIdentity: owner,
                localHouseholdId: Self.householdId,
                now: Self.now
            )
            Issue.record("Expected householdMismatch")
        } catch OperatorAuthorizationSignerError.householdMismatch {
            #expect(signerCalled == false, "signer must NOT be invoked when household mismatches (FR-009)")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func cursorAdvancesProduceDistinctSignedContexts() throws {
        let privateKey = try Self.ownerKey()
        let owner = try Self.ownerIdentity(signing: privateKey)
        let signer = OperatorAuthorizationSigner()
        let env = Self.envelope()

        let firstCursor = try signer.sign(
            envelope: env,
            cursor: 1,
            ownerIdentity: owner,
            localHouseholdId: Self.householdId,
            now: Self.now
        )
        let secondCursor = try signer.sign(
            envelope: env,
            cursor: 2,
            ownerIdentity: owner,
            localHouseholdId: Self.householdId,
            now: Self.now
        )
        // Different cursors → different signed contexts → different signatures.
        // This is the reordering-attack defense from FR-008.
        #expect(firstCursor.signedContext != secondCursor.signedContext)
        #expect(firstCursor.approvalSignature != secondCursor.approvalSignature)
    }
}
