import Foundation
import LocalAuthentication
import Testing
@testable import SoyehtCore

@Suite("OwnerIdentityKey")
struct OwnerIdentityKeyTests {
    @Test func inMemoryOwnerIdentitySignsWithInjectedSigner() throws {
        let publicKey = HouseholdTestFixtures.publicKey(byte: 0x55)
        let key = try InMemoryOwnerIdentityKey(publicKey: publicKey) { payload in
            Data(payload.reversed())
        }

        #expect(key.publicKey == publicKey)
        #expect(key.personId == (try HouseholdIdentifiers.personIdentifier(for: publicKey)))
        #expect(try key.sign(Data([1, 2, 3])) == Data([3, 2, 1]))
    }

    @Test func derSignatureConvertsToRawP256Signature() throws {
        let r = Data(repeating: 0x11, count: 32)
        let s = Data(repeating: 0x22, count: 32)
        let der = Data([0x30, 0x44, 0x02, 0x20]) + r + Data([0x02, 0x20]) + s
        #expect(try OwnerIdentityKey.rawP256Signature(fromDER: der) == r + s)
    }

    /// Detects LAError.biometryLockout when wrapped directly as the OSStatus
    /// CFError — the simplest shape SecKey can surface.
    @Test func isBiometryLockoutDetectsDirectLAError() {
        let error = NSError(
            domain: LAError.errorDomain,
            code: LAError.Code.biometryLockout.rawValue
        )
        #expect(OwnerIdentityKey.isBiometryLockout(error))
    }

    /// Detects LAError.biometryLockout when SecKey wraps the LA failure as
    /// `NSUnderlyingError` of an OSStatus error — the real-world shape from
    /// `SecKeyCreateSignature` against a `.biometryCurrentSet`-protected key.
    @Test func isBiometryLockoutWalksUnderlyingErrorChain() {
        let underlying = NSError(
            domain: LAError.errorDomain,
            code: LAError.Code.biometryLockout.rawValue
        )
        let secOuter = NSError(
            domain: NSOSStatusErrorDomain,
            code: -25293,  // errSecAuthFailed
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(OwnerIdentityKey.isBiometryLockout(secOuter))
    }

    /// Other LA errors (cancel, app-cancel, notInteractive) MUST NOT be
    /// confused with lockout — only `biometryLockout` qualifies.
    @Test func isBiometryLockoutRejectsOtherLAErrors() {
        let cancel = NSError(
            domain: LAError.errorDomain,
            code: LAError.Code.userCancel.rawValue
        )
        let notInteractive = NSError(
            domain: LAError.errorDomain,
            code: LAError.Code.notInteractive.rawValue
        )
        #expect(!OwnerIdentityKey.isBiometryLockout(cancel))
        #expect(!OwnerIdentityKey.isBiometryLockout(notInteractive))
    }

    @Test func isBiometryLockoutRejectsArbitraryOSStatusErrors() {
        let other = NSError(domain: NSOSStatusErrorDomain, code: -25291)
        #expect(!OwnerIdentityKey.isBiometryLockout(other))
    }
}
