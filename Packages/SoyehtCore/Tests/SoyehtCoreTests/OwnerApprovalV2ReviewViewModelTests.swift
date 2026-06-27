#if canImport(AuthenticationServices)
import Foundation
import Testing

@testable import SoyehtCore

/// Headless tests for the approval-v2 review view-model. These prove the UI
/// seam can render a prepared pair-machine context before the gesture, and that
/// confirmation only uses the stored prepared bundle after an explicit call.
@Suite struct OwnerApprovalV2ReviewViewModelTests {
    private struct SampleError: Error {}

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _prepare = 0
        private var _confirm = 0
        private var _confirmed: PreparedOwnerApprovalV2?

        func prepare() {
            lock.lock()
            _prepare += 1
            lock.unlock()
        }

        func confirm(_ prepared: PreparedOwnerApprovalV2) {
            lock.lock()
            _confirm += 1
            _confirmed = prepared
            lock.unlock()
        }

        var prepareCount: Int { lock.lock(); defer { lock.unlock() }; return _prepare }
        var confirmCount: Int { lock.lock(); defer { lock.unlock() }; return _confirm }
        var confirmed: PreparedOwnerApprovalV2? {
            lock.lock()
            defer { lock.unlock() }
            return _confirmed
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private static func context(op: OwnerApprovalOperation = .pairMachineApprove) -> OwnerApprovalContextV2 {
        OwnerApprovalContextV2(
            op: op,
            householdID: "hh_test",
            ownerPersonID: "p_owner",
            cursor: 7,
            machineID: "m_test",
            addr: "192.0.2.10:8091",
            transport: "lan",
            capabilities: ["machine-cert", "shamir-2pc"],
            issuedAt: 1000,
            expiresAt: 1600,
            replayNonce: Data([0x33, 0x33, 0x33, 0x33])
        )
    }

    private static func prepared(
        cursor: UInt64 = 7,
        context: OwnerApprovalContextV2 = context()
    ) throws -> PreparedOwnerApprovalV2 {
        let publicKey: [String: HouseholdCBORValue] = [
            "rpId": .text("alpha.example.test"),
            "challenge": .text(Data([0xDE, 0xAD, 0xBE, 0xEF]).soyehtBase64URLEncodedString()),
            "userVerification": .text("required"),
            "allowCredentials": .array([
                .map([
                    "type": .text("public-key"),
                    "id": .text(Data([0x00, 0x01, 0x02]).soyehtBase64URLEncodedString()),
                ]),
            ]),
        ]
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "challenge_id": .text("challenge-id-abc"),
            "context": context.cborValue(),
            "options": .map(["publicKey": .map(publicKey)]),
        ]))
        let start = try OwnerApprovalV2StartResponse(cbor: BootstrapWire.decodeCanonical(body))
        return PreparedOwnerApprovalV2(cursor: cursor, startResponse: start)
    }

    // MARK: prepare

    @Test @MainActor func prepareExposesPairMachineContextWithoutConfirming() async throws {
        let calls = Calls()
        let expected = try Self.prepared()
        let vm = OwnerApprovalV2ReviewViewModel(
            prepare: { calls.prepare(); return expected },
            confirm: { prepared in calls.confirm(prepared) }
        )

        await vm.prepare()

        #expect(vm.phase == .prepared(expected.startResponse.context))
        #expect(calls.prepareCount == 1)
        #expect(calls.confirmCount == 0)
    }

    @Test @MainActor func prepareRejectsNonPairMachineContextGenerically() async throws {
        let calls = Calls()
        let prepared = try Self.prepared(context: Self.context(op: .bootstrapTeardown))
        let vm = OwnerApprovalV2ReviewViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in calls.confirm(prepared) }
        )

        await vm.prepare()

        #expect(vm.phase == .failed(canRetry: true))
        #expect(calls.prepareCount == 1)
        #expect(calls.confirmCount == 0)
    }

    @Test @MainActor func prepareFailureNeverBranchesOnErrorCode() async {
        let opaque401 = OwnerApprovalV2ReviewViewModel(
            prepare: { throw BootstrapError.serverError(code: "unauthenticated", message: nil) },
            confirm: { _ in Issue.record("confirm should not run") }
        )
        await opaque401.prepare()

        let otherError = OwnerApprovalV2ReviewViewModel(
            prepare: { throw SampleError() },
            confirm: { _ in Issue.record("confirm should not run") }
        )
        await otherError.prepare()

        #expect(opaque401.phase == .failed(canRetry: true))
        #expect(otherError.phase == .failed(canRetry: true))
        #expect(opaque401.phase == otherError.phase)
    }

    // MARK: confirm

    @Test @MainActor func confirmUsesPreparedBundleOnlyAfterPrepare() async throws {
        let calls = Calls()
        let prepared = try Self.prepared(cursor: 9)
        let vm = OwnerApprovalV2ReviewViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in calls.confirm(prepared) }
        )

        await vm.confirm()
        #expect(calls.confirmCount == 0)  // no prepared bundle yet

        await vm.prepare()
        await vm.confirm()

        #expect(vm.phase == .completed)
        #expect(calls.confirmCount == 1)
        let confirmed = try #require(calls.confirmed)
        #expect(confirmed.cursor == 9)
        #expect(confirmed.startResponse.context == prepared.startResponse.context)
        #expect(confirmed.startResponse.challenge == prepared.startResponse.challenge)
    }

    @Test @MainActor func confirmFailureFailsGenericallyAndRequiresFreshPrepare() async throws {
        let calls = Calls()
        let prepared = try Self.prepared()
        let vm = OwnerApprovalV2ReviewViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in calls.confirm(prepared); throw BootstrapError.serverError(code: "unauthenticated", message: nil) }
        )

        await vm.prepare()
        await vm.confirm()

        #expect(vm.phase == .failed(canRetry: true))
        #expect(calls.confirmCount == 1)

        await vm.confirm()
        #expect(calls.confirmCount == 1)  // failed phase does not reuse stale challenge
    }

    // MARK: reentrancy

    @Test @MainActor func reentrantPrepareWhilePreparingIsIgnored() async throws {
        let calls = Calls()
        let gate = Gate()
        let prepared = try Self.prepared()
        let vm = OwnerApprovalV2ReviewViewModel(
            prepare: { calls.prepare(); await gate.wait(); return prepared },
            confirm: { prepared in calls.confirm(prepared) }
        )

        let first = Task { await vm.prepare() }
        while vm.phase != .preparing { await Task.yield() }

        await vm.prepare()
        await gate.open()
        await first.value

        #expect(calls.prepareCount == 1)
        #expect(vm.phase == .prepared(prepared.startResponse.context))
    }

    @Test @MainActor func reentrantConfirmWhileConfirmingIsIgnored() async throws {
        let calls = Calls()
        let gate = Gate()
        let prepared = try Self.prepared()
        let vm = OwnerApprovalV2ReviewViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in calls.confirm(prepared); await gate.wait() }
        )

        await vm.prepare()
        let first = Task { await vm.confirm() }
        while vm.phase != .confirming { await Task.yield() }

        await vm.confirm()
        await gate.open()
        await first.value

        #expect(calls.confirmCount == 1)
        #expect(vm.phase == .completed)
    }
}
#endif
