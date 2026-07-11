#if DEBUG
import Foundation
import Testing

@testable import SoyehtCore

@Suite struct MobileClawVPNOwnerPresentBoundaryTests {
    @Test @MainActor
    func prepareExposesOnlySanitizedReviewAndPerformsNoFinishOrMint() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { context, _ in
                recorder.record("start", context: context)
                return (binding, "prepared")
            },
            finish: { context, prepared, _ in
                recorder.record("finish:\(prepared)", context: context)
                return "finish-artifact"
            },
            mint: { context, _ in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )

        await coordinator.prepare(target: .clawM)

        guard case .prepared(let review) = coordinator.phase else {
            Issue.record("expected sanitized prepared review")
            return
        }
        #expect(recorder.events == ["start"])
        #expect(review.description.contains("Device-D"))
        #expect(review.description.contains("Claw-M"))
        #expect(review.runReference == "33333333")
        #expect(review.artifactReference == "aaaaaaaa")
        #expect(review.expiresAtUnixSeconds == binding.approvalContext.expiresAt)
        #expect(!review.description.contains("engine-a"))
        #expect(!review.description.contains(binding.execution.householdID))
        #expect(!review.description.contains(binding.approvalContext.ownerPersonID))
        #expect(!review.description.contains(binding.execution.memberID))
        #expect(!review.description.contains(binding.execution.deviceID))
        #expect(!review.description.contains(binding.execution.clawID))
        #expect(review.customMirror.children.count == 1)
        #expect(review.customMirror.children.first?.label == "description")
    }

    @Test @MainActor
    func pinnedContextSurvivesAmbientContextChangeAcrossStartFinishAndMint() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let expectedContextBytes = try binding.approvalContext.canonicalBytes()
        let expectedChallengeDigest = try binding.approvalContext.challengeDigest()
        var ambientContext = "engine-a"
        let pinnedContext = ambientContext
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: pinnedContext,
            start: { context, _ in
                recorder.record("start", context: context)
                return (binding, "prepared")
            },
            finish: { context, _, submittedContext in
                recorder.record("finish", context: context)
                let submittedContextBytes = try submittedContext.canonicalBytes()
                let submittedChallengeDigest = try submittedContext.challengeDigest()
                #expect(submittedContextBytes == expectedContextBytes)
                #expect(submittedChallengeDigest == expectedChallengeDigest)
                return "finish-artifact"
            },
            mint: { context, _ in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )
        ambientContext = "engine-b"

        await coordinator.prepare(target: .clawM)
        await coordinator.confirm()

        #expect(ambientContext == "engine-b")
        #expect(recorder.events == ["start", "finish", "mint"])
        #expect(recorder.contexts == ["engine-a", "engine-a", "engine-a"])
        #expect(
            coordinator.phase == .completed(
                try MobileClawVPNOwnerPresentSummary(status: Self.status())
            )
        )
    }

    @Test @MainActor
    func targetMismatchFailsBeforeFinishAndMint() async throws {
        let recorder = Recorder()
        let wrongBinding = try Self.binding(target: .clawL)
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { context, _ in
                recorder.record("start", context: context)
                return (wrongBinding, "prepared")
            },
            finish: { context, _, _ in
                recorder.record("finish", context: context)
                return "finish-artifact"
            },
            mint: { context, _ in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )

        await coordinator.prepare(target: .clawM)
        await coordinator.confirm()

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.events == ["start"])
    }

    @Test @MainActor
    func finishFailureSpendsPreparedOperationAndNeverMints() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { _, _ in (binding, "prepared") },
            finish: { context, _, _ in
                recorder.record("finish", context: context)
                throw TestError.finish
            },
            mint: { (context: String, _: String) in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )

        await coordinator.prepare(target: .clawM)
        await coordinator.confirm()
        await coordinator.confirm()

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.count("finish") == 1)
        #expect(recorder.count("mint") == 0)
    }

    @Test @MainActor
    func responseLossAfterSinkEffectDoesNotRearmMint() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { _, _ in (binding, "prepared") },
            finish: { _, _, _ in "finish-artifact" },
            mint: { context, _ in
                recorder.record("mint", context: context)
                throw TestError.responseLost
            }
        )

        await coordinator.prepare(target: .clawM)
        await coordinator.confirm()
        await coordinator.confirm()

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.count("mint") == 1)
    }

    @Test @MainActor
    func concurrentConfirmInvokesFinishAndMintExactlyOnce() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { _, _ in (binding, "prepared") },
            finish: { context, _, _ in
                recorder.record("finish", context: context)
                try await Task.sleep(nanoseconds: 20_000_000)
                return "finish-artifact"
            },
            mint: { context, _ in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )
        await coordinator.prepare(target: .clawM)

        let first = Task { @MainActor in await coordinator.confirm() }
        let second = Task { @MainActor in await coordinator.confirm() }
        await first.value
        await second.value

        #expect(recorder.count("finish") == 1)
        #expect(recorder.count("mint") == 1)
        #expect(
            coordinator.phase == .completed(
                try MobileClawVPNOwnerPresentSummary(status: Self.status())
            )
        )
    }

    @Test
    func sharedOneShotStorageAllowsExactlyOneConcurrentConsumer() async {
        let recorder = Recorder()
        let outcomes = await MobileClawVPNOwnerPresentTestHarness.consumeOneShotConcurrently {
            recorder.record("effect", context: "engine-a")
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(outcomes.filter { $0 == .success }.count == 1)
        #expect(outcomes.filter { $0 == .consumed }.count == 1)
        #expect(outcomes.filter { $0 == .failure }.isEmpty)
        #expect(recorder.count("effect") == 1)
    }

}
#endif
