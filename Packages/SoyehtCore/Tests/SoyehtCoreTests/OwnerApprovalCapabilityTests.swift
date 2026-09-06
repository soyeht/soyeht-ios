import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import SoyehtCore

@Suite("Owner approval capability")
struct OwnerApprovalCapabilityTests {
    private func fixture() throws -> (ActiveHouseholdState, PairingAuthority, InMemoryOwnerIdentityKey) {
        let owner = P256.Signing.PrivateKey()
        let root = P256.Signing.PrivateKey()
        let signer = try InMemoryOwnerIdentityKey(publicKey: owner.publicKey.compressedRepresentation) {
            try owner.signature(for: $0).rawRepresentation
        }
        let cert = try PersonCert(cbor: HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: root, personPublicKey: signer.publicKey,
            householdId: "hh_test", now: Date()))
        let session = ActiveHouseholdState(householdId: "hh_test", householdName: "Test Home",
            householdPublicKey: root.publicKey.compressedRepresentation,
            endpoint: URL(string: "http://192.168.1.20:8091")!, ownerPersonId: signer.personId,
            ownerPublicKey: signer.publicKey, ownerKeyReference: signer.keyReference,
            personCert: cert, pairedAt: Date(), lastSeenAt: nil)
        return (session, PairingAuthority(householdID: session.householdId,
            ownerPersonID: signer.personId, ownerPublicKey: signer.publicKey), signer)
    }

    @Test func requiresAnActualFreshSignature() throws {
        let (session, authority, signer) = try fixture()
        let checker = OwnerApprovalCapabilityChecker(loadSession: { session }, loadSigner: { _ in signer })
        #expect(checker.check(authority: authority).state == .proven)
        let wrongKey = P256.Signing.PrivateKey()
        let dishonestSigner = try InMemoryOwnerIdentityKey(publicKey: signer.publicKey) {
            try wrongKey.signature(for: $0).rawRepresentation
        }
        let wrong = OwnerApprovalCapabilityChecker(loadSession: { session }, loadSigner: { _ in dishonestSigner })
        #expect(wrong.check(authority: authority).state == .identityMismatch)
    }

    @Test func absentSessionDoesNotReadAKey() throws {
        let (_, authority, _) = try fixture()
        let checker = OwnerApprovalCapabilityChecker(loadSession: { nil }, loadSigner: { _ in
            Issue.record("An absent session must not cause a key lookup")
            throw OwnerIdentityKeyError.keyNotFound
        })
        #expect(checker.check(authority: authority).state == .noSession)
    }

    @Test func anotherHouseDoesNotReadAKey() throws {
        let (session, _, _) = try fixture()
        let checker = OwnerApprovalCapabilityChecker(loadSession: { session }, loadSigner: { _ in
            Issue.record("A mismatched house must not cause a key lookup")
            throw OwnerIdentityKeyError.keyNotFound
        })
        #expect(checker.check(authority: PairingAuthority(householdID: "hh_other",
            ownerPersonID: session.ownerPersonId, ownerPublicKey: session.ownerPublicKey)).state == .identityMismatch)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled])
    func lockedKeyAndLockedSessionRequireAuthentication(status: OSStatus) throws {
        let (session, authority, _) = try fixture()
        let error = OwnerIdentityKeyError.securityFailure(domain: NSOSStatusErrorDomain, code: Int(status))
        let key = OwnerApprovalCapabilityChecker(loadSession: { session }, loadSigner: { _ in throw error })
        let storage = OwnerApprovalCapabilityChecker(loadSession: { throw error }, loadSigner: { _ in
            Issue.record("Unavailable session must not load a signer")
            throw OwnerIdentityKeyError.keyNotFound
        })
        #expect(key.check(authority: authority).state == .needsAuthentication)
        #expect(storage.check(authority: authority).state == .needsAuthentication)
        #expect(key.check(authority: authority).diagnostic.contains("security_\(status)"))
    }

    @Test func absentKeyIsDistinctFromUnknownSecurityFailure() throws {
        let (session, authority, _) = try fixture()
        let missing = OwnerApprovalCapabilityChecker(loadSession: { session }, loadSigner: { _ in
            throw OwnerIdentityKeyError.keyNotFound
        })
        let unavailable = OwnerApprovalCapabilityChecker(loadSession: { session }, loadSigner: { _ in
            throw OwnerIdentityKeyError.securityFailure(domain: NSOSStatusErrorDomain, code: Int(errSecNotAvailable))
        })
        #expect(missing.check(authority: authority).state == .noKey)
        #expect(unavailable.check(authority: authority).state == .error)
    }

    @Test func wrappedAuthenticationFailureIsPreserved() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInternalComponent),
            userInfo: [NSUnderlyingErrorKey: NSError(domain: LAError.errorDomain,
                code: LAError.Code.notInteractive.rawValue)])
        #expect(OwnerApprovalCapability.failure(error).state == .needsAuthentication)
        #expect(OwnerApprovalCapability.failure(OwnerIdentityKey.securityFailure(error)).state == .needsAuthentication)
    }
}
