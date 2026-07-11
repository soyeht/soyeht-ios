#if DEBUG
import Testing

@testable import SoyehtCore

extension MobileClawVPNOwnerPresentBoundaryTests {
    @Test @MainActor
    func cancellationDuringFinishBurnsWithoutMintOrRetry() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { _, _ in (binding, "prepared") },
            finish: { context, _, _ in
                recorder.record("finish", context: context)
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "finish-artifact"
            },
            mint: { context, _ in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )
        await coordinator.prepare(target: .clawM)

        let task = Task { @MainActor in await coordinator.confirm() }
        while recorder.count("finish") == 0 {
            await Task.yield()
        }
        task.cancel()
        await task.value
        await coordinator.confirm()

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.count("finish") == 1)
        #expect(recorder.count("mint") == 0)
    }

    @Test @MainActor
    func alreadyCancelledPrepareDoesNotInvokeStart() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { context, _ in
                recorder.record("start", context: context)
                return (binding, "prepared")
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

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await coordinator.prepare(target: .clawM)
        }
        await task.value

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.events.isEmpty)
    }

    @Test @MainActor
    func alreadyCancelledConfirmSpendsPreparedWithoutFinishOrMint() async throws {
        let recorder = Recorder()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { _, _ in (binding, "prepared") },
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

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await coordinator.confirm()
        }
        await task.value
        await coordinator.confirm()

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.events.isEmpty)
    }

    @Test @MainActor
    func cancellationAfterStartReturnsCannotPublishPreparedState() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { context, _ in
                recorder.record("start", context: context)
                await gate.wait()
                return (binding, "prepared")
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

        let task = Task { @MainActor in await coordinator.prepare(target: .clawM) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await task.value

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.events == ["start"])
    }

    @Test @MainActor
    func cancellationAfterFinishReturnsSpendsLeaseBeforeMint() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let binding = try Self.binding()
        let coordinator = MobileClawVPNOwnerPresentTestHarness.makeCoordinator(
            context: "engine-a",
            start: { _, _ in (binding, "prepared") },
            finish: { context, _, _ in
                recorder.record("finish", context: context)
                await gate.wait()
                return "finish-artifact"
            },
            mint: { context, _ in
                recorder.record("mint", context: context)
                return try MobileClawVPNOwnerPresentSummary(status: Self.status())
            }
        )
        await coordinator.prepare(target: .clawM)

        let task = Task { @MainActor in await coordinator.confirm() }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await task.value
        await coordinator.confirm()

        #expect(coordinator.phase == .failed(canRetry: true))
        #expect(recorder.count("finish") == 1)
        #expect(recorder.count("mint") == 0)
    }
}
#endif
