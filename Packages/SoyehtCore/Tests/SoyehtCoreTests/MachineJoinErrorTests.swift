import Foundation
import Testing
@testable import SoyehtCore

@Suite("MachineJoinError")
struct MachineJoinErrorTests {

    // MARK: - Equatable / case identity

    @Test func sameCasesAreEqualAcrossInstances() {
        #expect(MachineJoinError.qrExpired == MachineJoinError.qrExpired)
        #expect(MachineJoinError.hhMismatch == MachineJoinError.hhMismatch)
        #expect(MachineJoinError.biometricCancel == MachineJoinError.biometricCancel)
        #expect(MachineJoinError.biometricLockout == MachineJoinError.biometricLockout)
        #expect(MachineJoinError.macUnreachable == MachineJoinError.macUnreachable)
        #expect(MachineJoinError.networkDrop == MachineJoinError.networkDrop)
        #expect(MachineJoinError.gossipDisconnect == MachineJoinError.gossipDisconnect)
        #expect(MachineJoinError.derivationDrift == MachineJoinError.derivationDrift)
        #expect(
            MachineJoinError.serverError(code: "rate_limited", message: "slow down") ==
            MachineJoinError.serverError(code: "rate_limited", message: "slow down")
        )
    }

    @Test func differentReasonsAreNotEqual() {
        #expect(
            MachineJoinError.qrInvalid(reason: .schemaUnsupported) !=
            MachineJoinError.qrInvalid(reason: .invalidPublicKey)
        )
        #expect(
            MachineJoinError.qrInvalid(reason: .missingField(name: "v")) !=
            MachineJoinError.qrInvalid(reason: .missingField(name: "m_pub"))
        )
        #expect(
            MachineJoinError.certValidationFailed(reason: .schemaInvalid) !=
            MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        )
        #expect(
            MachineJoinError.protocolViolation(detail: .malformedErrorBody) !=
            MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        )
    }

    @Test func crossCaseInequality() {
        #expect(MachineJoinError.qrExpired != MachineJoinError.networkDrop)
        #expect(MachineJoinError.biometricCancel != MachineJoinError.biometricLockout)
        #expect(MachineJoinError.macUnreachable != MachineJoinError.networkDrop)
        #expect(MachineJoinError.hhMismatch != MachineJoinError.derivationDrift)
    }

    // MARK: - PairMachineQRError adapter

    @Test func pairMachineQRErrorMapsExpiredToTopLevel() {
        let error = MachineJoinError(PairMachineQRError.expired)
        #expect(error == .qrExpired)
    }

    @Test func pairMachineQRErrorSchemaCasesCollapseToSchemaUnsupported() {
        #expect(MachineJoinError(PairMachineQRError.unsupportedScheme)
                == .qrInvalid(reason: .schemaUnsupported))
        #expect(MachineJoinError(PairMachineQRError.unsupportedPath)
                == .qrInvalid(reason: .schemaUnsupported))
        #expect(MachineJoinError(PairMachineQRError.unsupportedVersion("9"))
                == .qrInvalid(reason: .schemaUnsupported))
    }

    @Test func pairMachineQRErrorMissingFieldPreservesName() {
        let error = MachineJoinError(PairMachineQRError.missingField("challenge_sig"))
        #expect(error == .qrInvalid(reason: .missingField(name: "challenge_sig")))
    }

    @Test func pairMachineQRErrorPublicKeyCases() {
        #expect(MachineJoinError(PairMachineQRError.invalidMachinePublicKey)
                == .qrInvalid(reason: .invalidPublicKey))
    }

    @Test func pairMachineQRErrorNonceCasesCollapse() {
        #expect(MachineJoinError(PairMachineQRError.invalidNonceEncoding)
                == .qrInvalid(reason: .invalidNonce))
        #expect(MachineJoinError(PairMachineQRError.invalidNonce)
                == .qrInvalid(reason: .invalidNonce))
    }

    @Test func pairMachineQRErrorHostnameAndAddressCases() {
        #expect(MachineJoinError(PairMachineQRError.emptyHostname)
                == .qrInvalid(reason: .invalidHostname))
        #expect(MachineJoinError(PairMachineQRError.emptyAddress)
                == .qrInvalid(reason: .invalidAddress))
    }

    @Test func pairMachineQRErrorPlatformAndTransportPreserveValue() {
        #expect(MachineJoinError(PairMachineQRError.unsupportedPlatform("openbsd"))
                == .qrInvalid(reason: .unsupportedPlatform(value: "openbsd")))
        #expect(MachineJoinError(PairMachineQRError.unsupportedTransport("zeroconf"))
                == .qrInvalid(reason: .unsupportedTransport(value: "zeroconf")))
    }

    @Test func pairMachineQRErrorAllChallengeSigCasesCollapse() {
        #expect(MachineJoinError(PairMachineQRError.invalidChallengeSignatureEncoding)
                == .qrInvalid(reason: .challengeSigInvalid))
        #expect(MachineJoinError(PairMachineQRError.invalidChallengeSignatureLength(63))
                == .qrInvalid(reason: .challengeSigInvalid))
        #expect(MachineJoinError(PairMachineQRError.challengeSignatureVerificationFailed)
                == .qrInvalid(reason: .challengeSigInvalid))
    }

    @Test func pairMachineQRErrorTTLCasesCollapse() {
        #expect(MachineJoinError(PairMachineQRError.invalidExpiry)
                == .qrInvalid(reason: .ttlOutOfRange))
        #expect(MachineJoinError(PairMachineQRError.ttlExceedsMaxAllowed(seconds: 600, max: 300))
                == .qrInvalid(reason: .ttlOutOfRange))
    }

    /// Exhaustiveness sentinel: if `PairMachineQRError` grows a new case the
    /// compiler will fail the `init` switch first; this test additionally
    /// asserts every case currently round-trips into a non-nil mapping so a
    /// silent default would be caught by a deliberate compile break.
    @Test func everyPairMachineQRErrorMapsToATypedMachineJoinError() {
        let cases: [PairMachineQRError] = [
            .unsupportedScheme,
            .unsupportedPath,
            .missingField("v"),
            .unsupportedVersion("2"),
            .invalidMachinePublicKey,
            .invalidNonceEncoding,
            .invalidNonce,
            .emptyHostname,
            .unsupportedPlatform("plan9"),
            .unsupportedTransport("usb"),
            .emptyAddress,
            .invalidChallengeSignatureEncoding,
            .invalidChallengeSignatureLength(0),
            .challengeSignatureVerificationFailed,
            .invalidExpiry,
            .expired,
            .ttlExceedsMaxAllowed(seconds: 99_999, max: 300),
        ]
        for raw in cases {
            // Forces every case to land in either qrInvalid or qrExpired.
            switch MachineJoinError(raw) {
            case .qrInvalid, .qrExpired: continue
            default: Issue.record("unexpected MachineJoinError mapping for \(raw)")
            }
        }
    }

    // MARK: - MachineCertError adapter

    @Test func machineCertErrorSchemaCasesCollapse() {
        #expect(MachineJoinError(MachineCertError.malformed)
                == .certValidationFailed(reason: .schemaInvalid))
        #expect(MachineJoinError(MachineCertError.nonCanonicalEncoding)
                == .certValidationFailed(reason: .schemaInvalid))
        #expect(MachineJoinError(MachineCertError.unknownFields(["caveats"]))
                == .certValidationFailed(reason: .schemaInvalid))
        #expect(MachineJoinError(MachineCertError.unsupportedVersion)
                == .certValidationFailed(reason: .schemaInvalid))
        #expect(MachineJoinError(MachineCertError.wrongType)
                == .certValidationFailed(reason: .schemaInvalid))
    }

    @Test func machineCertErrorIdentityMismatchCases() {
        #expect(MachineJoinError(MachineCertError.invalidMachinePublicKey)
                == .certValidationFailed(reason: .identityMismatch))
        #expect(MachineJoinError(MachineCertError.machineIdMismatch)
                == .certValidationFailed(reason: .identityMismatch))
    }

    @Test func machineCertErrorIssuerCases() {
        #expect(MachineJoinError(MachineCertError.householdMismatch)
                == .certValidationFailed(reason: .wrongIssuer))
        #expect(MachineJoinError(MachineCertError.invalidIssuer)
                == .certValidationFailed(reason: .wrongIssuer))
    }

    @Test func machineCertErrorFieldRangeCases() {
        #expect(MachineJoinError(MachineCertError.unsupportedPlatform)
                == .certValidationFailed(reason: .fieldOutOfRange))
        #expect(MachineJoinError(MachineCertError.invalidHostname)
                == .certValidationFailed(reason: .fieldOutOfRange))
        #expect(MachineJoinError(MachineCertError.invalidJoinedAt)
                == .certValidationFailed(reason: .fieldOutOfRange))
    }

    @Test func machineCertErrorSignatureCases() {
        #expect(MachineJoinError(MachineCertError.invalidSignatureLength)
                == .certValidationFailed(reason: .signatureInvalid))
        #expect(MachineJoinError(MachineCertError.invalidSignature)
                == .certValidationFailed(reason: .signatureInvalid))
    }

    @Test func machineCertErrorRevoked() {
        #expect(MachineJoinError(MachineCertError.revoked)
                == .certValidationFailed(reason: .revoked))
    }

    @Test func everyMachineCertErrorMapsToCertValidationFailed() {
        let cases: [MachineCertError] = [
            .malformed,
            .nonCanonicalEncoding,
            .unknownFields(["x"]),
            .unsupportedVersion,
            .wrongType,
            .invalidMachinePublicKey,
            .machineIdMismatch,
            .householdMismatch,
            .invalidIssuer,
            .unsupportedPlatform,
            .invalidHostname,
            .invalidSignatureLength,
            .invalidSignature,
            .revoked,
            .invalidJoinedAt,
        ]
        for raw in cases {
            switch MachineJoinError(raw) {
            case .certValidationFailed: continue
            default: Issue.record("unexpected MachineJoinError mapping for \(raw)")
            }
        }
    }

    // MARK: - OperatorAuthorizationSignerError adapter

    @Test func signerErrorAdapterCoversBiometricAndHouseholdCases() {
        #expect(MachineJoinError(OperatorAuthorizationSignerError.biometryCanceled) == .biometricCancel)
        #expect(MachineJoinError(OperatorAuthorizationSignerError.biometryLockout) == .biometricLockout)
        #expect(MachineJoinError(OperatorAuthorizationSignerError.householdMismatch) == .hhMismatch)
    }

    @Test func signerErrorSigningFailedReturnsNilForCallerToHandle() {
        // `.signingFailed` is a low-level CryptoKit/SecKey error. The caller
        // (UI layer) is expected to surface a generic message rather than a
        // join-flow-specific one, so the adapter intentionally returns nil.
        #expect(MachineJoinError(OperatorAuthorizationSignerError.signingFailed) == nil)
    }
}
