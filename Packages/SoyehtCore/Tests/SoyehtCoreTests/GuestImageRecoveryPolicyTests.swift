import Testing

@testable import SoyehtCore

@Suite struct GuestImageRecoveryPolicyTests {
    // MARK: - CTA bifurcation (shared rule)

    @Test func ctaSplitsPrepareFromCheckAgain() {
        #expect(GuestImageRecoveryAction.retry.cta == .prepare)
        #expect(GuestImageRecoveryAction.freeSpaceThenRetry.cta == .prepare)
        #expect(GuestImageRecoveryAction.restartMacRequired.cta == .checkAgain)
        #expect(GuestImageRecoveryAction.openSoyehtOnMac.cta == .checkAgain)
        #expect(GuestImageRecoveryAction.reinstallSoyehtOnMac.cta == .checkAgain)
        #expect(GuestImageRecoveryAction.none.cta == .none)
    }

    // MARK: - readiness → presentation

    @Test func readyAndNotApplicableHaveNoRecovery() {
        #expect(GuestImageRecoveryPolicy.presentation(for: .ready) == nil)
        #expect(GuestImageRecoveryPolicy.presentation(for: .notApplicable) == nil)
    }

    @Test func preparingStatesAreMarkedPreparingWithNoAction() {
        for readiness in [GuestImageReadiness.notStarted, .inProgress(phase: "download_ipsw")] {
            let p = try! #require(GuestImageRecoveryPolicy.presentation(for: readiness))
            #expect(p.isPreparing)
            #expect(!p.isFailed)
            #expect(p.action == GuestImageRecoveryAction.none)
            #expect(p.cta == .none)
            #expect(p.failureCode == nil)
        }
    }

    @Test func hostVmLimitMapsToRestartCheckAgain() {
        let p = try! #require(GuestImageRecoveryPolicy.presentation(for: .failed(error: "vz", code: .hostVmLimitReached)))
        #expect(p.isFailed)
        #expect(p.failureCode == .hostVmLimitReached)
        #expect(p.action == .restartMacRequired)
        #expect(p.cta == .checkAgain)
        #expect(!p.isRecoverableOnDevice)
    }

    @Test func insufficientDiskMapsToPrepareAndOnDevice() {
        let p = try! #require(GuestImageRecoveryPolicy.presentation(for: .failed(error: nil, code: .insufficientDisk)))
        #expect(p.action == .freeSpaceThenRetry)
        #expect(p.cta == .prepare)
        #expect(p.isRecoverableOnDevice)
    }

    @Test func ipswIncompatibleOffersNoCTA() {
        let p = try! #require(GuestImageRecoveryPolicy.presentation(for: .failed(error: nil, code: .ipswIncompatible)))
        #expect(p.action == GuestImageRecoveryAction.none)
        #expect(p.cta == .none)
        #expect(!p.isRecoverableOnDevice)
    }

    @Test func virtualizationUnavailableOffersNoCTA() {
        // Terminal/ambiguous: the policy must produce no mutating CTA and never a
        // prepare/Try Again, so an unsupportable Mac isn't offered an endless retry.
        let p = try! #require(GuestImageRecoveryPolicy.presentation(for: .failed(error: nil, code: .virtualizationUnavailable)))
        #expect(p.action == GuestImageRecoveryAction.none)
        #expect(p.cta == .none)
        #expect(p.cta != .prepare)
        #expect(!p.isRecoverableOnDevice)
    }

    @Test func absentOrUnknownFailureCodeFallsBackToRetry() {
        // Older engine: failed with no code.
        let noCode = try! #require(GuestImageRecoveryPolicy.presentation(for: .failed(error: "boom", code: nil)))
        #expect(noCode.failureCode == nil)
        #expect(noCode.action == .retry)
        #expect(noCode.cta == .prepare)
        // Present-but-unrecognized → .unknown → retry.
        let unknown = try! #require(GuestImageRecoveryPolicy.presentation(for: .failed(error: nil, code: .unknown)))
        #expect(unknown.action == .retry)
        #expect(unknown.cta == .prepare)
    }
}
