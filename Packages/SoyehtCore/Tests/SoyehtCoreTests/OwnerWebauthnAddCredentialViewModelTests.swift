#if canImport(AuthenticationServices)
import Foundation
import Testing

@testable import SoyehtCore

@Suite struct OwnerWebauthnAddCredentialViewModelTests {
    private struct SampleError: Error {}

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _prepare = 0
        private var _confirm = 0
        private var _confirmed: PreparedOwnerWebauthnAddCredential?

        func prepare() {
            lock.lock()
            _prepare += 1
            lock.unlock()
        }

        func confirm(_ prepared: PreparedOwnerWebauthnAddCredential) {
            lock.lock()
            _confirm += 1
            _confirmed = prepared
            lock.unlock()
        }

        var prepareCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _prepare
        }

        var confirmCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _confirm
        }

        var confirmed: PreparedOwnerWebauthnAddCredential? {
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

    @Test @MainActor func prepareExposesAddCredentialContextWithoutConfirming() async throws {
        let calls = Calls()
        let prepared = try Self.prepared()
        let vm = OwnerWebauthnAddCredentialViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in
                calls.confirm(prepared)
                return Self.result()
            }
        )

        await vm.prepare()

        #expect(vm.phase == .prepared(prepared.startResponse.context))
        #expect(calls.prepareCount == 1)
        #expect(calls.confirmCount == 0)
    }

    @Test @MainActor func prepareRejectsNonAddCredentialContextGenerically() async throws {
        let calls = Calls()
        let prepared = try Self.prepared(context: Self.context(op: .pairMachineApprove))
        let vm = OwnerWebauthnAddCredentialViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in
                calls.confirm(prepared)
                return Self.result()
            }
        )

        await vm.prepare()

        #expect(vm.phase == .failed(canRetry: true))
        #expect(calls.prepareCount == 1)
        #expect(calls.confirmCount == 0)
    }

    @Test @MainActor func prepareFailureNeverBranchesOnErrorCode() async {
        let opaque401 = OwnerWebauthnAddCredentialViewModel(
            prepare: { throw BootstrapError.serverError(code: "unauthenticated", message: nil) },
            confirm: { _ in
                Issue.record("confirm should not run")
                return Self.result()
            }
        )
        await opaque401.prepare()

        let otherError = OwnerWebauthnAddCredentialViewModel(
            prepare: { throw SampleError() },
            confirm: { _ in
                Issue.record("confirm should not run")
                return Self.result()
            }
        )
        await otherError.prepare()

        #expect(opaque401.phase == .failed(canRetry: true))
        #expect(otherError.phase == .failed(canRetry: true))
        #expect(opaque401.phase == otherError.phase)
    }

    @Test @MainActor func confirmUsesPreparedBundleOnlyAfterPrepare() async throws {
        let calls = Calls()
        let prepared = try Self.prepared()
        let result = Self.result()
        let vm = OwnerWebauthnAddCredentialViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in
                calls.confirm(prepared)
                return result
            }
        )

        await vm.confirm()
        #expect(calls.confirmCount == 0)

        await vm.prepare()
        await vm.confirm()

        #expect(vm.phase == .completed(result))
        #expect(calls.confirmCount == 1)
        let confirmed = try #require(calls.confirmed)
        #expect(confirmed.startResponse.context == prepared.startResponse.context)
        #expect(confirmed.startResponse.approval.challenge == prepared.startResponse.approval.challenge)
        #expect(confirmed.startResponse.registration.challengeID == prepared.startResponse.registration.challengeID)
    }

    @Test @MainActor func confirmFailureFailsGenericallyAndRequiresFreshPrepare() async throws {
        let calls = Calls()
        let prepared = try Self.prepared()
        let vm = OwnerWebauthnAddCredentialViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in
                calls.confirm(prepared)
                throw BootstrapError.serverError(code: "unauthenticated", message: nil)
            }
        )

        await vm.prepare()
        await vm.confirm()

        #expect(vm.phase == .failed(canRetry: true))
        #expect(calls.confirmCount == 1)

        await vm.confirm()
        #expect(calls.confirmCount == 1)
    }

    @Test @MainActor func reentrantPrepareWhilePreparingIsIgnored() async throws {
        let calls = Calls()
        let gate = Gate()
        let prepared = try Self.prepared()
        let vm = OwnerWebauthnAddCredentialViewModel(
            prepare: { calls.prepare(); await gate.wait(); return prepared },
            confirm: { prepared in
                calls.confirm(prepared)
                return Self.result()
            }
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
        let result = Self.result()
        let vm = OwnerWebauthnAddCredentialViewModel(
            prepare: { calls.prepare(); return prepared },
            confirm: { prepared in
                calls.confirm(prepared)
                await gate.wait()
                return result
            }
        )

        await vm.prepare()
        let first = Task { await vm.confirm() }
        while vm.phase != .confirming { await Task.yield() }

        await vm.confirm()
        await gate.open()
        await first.value

        #expect(calls.confirmCount == 1)
        #expect(vm.phase == .completed(result))
    }

    private static func prepared(
        context: OwnerApprovalContextV2 = context()
    ) throws -> PreparedOwnerWebauthnAddCredential {
        let registrationPublicKey: [String: HouseholdCBORValue] = [
            "rp": .map(["id": .text("alpha.example.test"), "name": .text("Soyeht")]),
            "user": .map([
                "id": .text(Data([0x01, 0x02]).soyehtBase64URLEncodedString()),
                "name": .text("p_owner"),
                "displayName": .text("Owner"),
            ]),
            "challenge": .text(Data([0x10, 0x11]).soyehtBase64URLEncodedString()),
        ]
        let approvalPublicKey: [String: HouseholdCBORValue] = [
            "rpId": .text("alpha.example.test"),
            "challenge": .text(Data([0x20, 0x21]).soyehtBase64URLEncodedString()),
            "userVerification": .text("required"),
            "allowCredentials": .array([
                .map([
                    "type": .text("public-key"),
                    "id": .text(Data([0x30, 0x31]).soyehtBase64URLEncodedString()),
                ]),
            ]),
        ]
        let body = HouseholdCBOR.encode(.map([
            "v": .unsigned(1),
            "registration": .map([
                "v": .unsigned(1),
                "challenge_id": .text("registration-challenge"),
                "options": .map(["publicKey": .map(registrationPublicKey)]),
            ]),
            "approval": .map([
                "v": .unsigned(1),
                "challenge_id": .text("approval-challenge"),
                "context": try context.cborValue(),
                "options": .map(["publicKey": .map(approvalPublicKey)]),
            ]),
            "context": try context.cborValue(),
        ]))
        return PreparedOwnerWebauthnAddCredential(
            startResponse: try OwnerWebauthnAddCredentialStartResponse(cbor: BootstrapWire.decodeCanonical(body))
        )
    }

    private static func context(op: OwnerApprovalOperation = .addCredential) -> OwnerApprovalContextV2 {
        OwnerApprovalContextV2(
            op: op,
            householdID: "hh_test",
            ownerPersonID: "p_owner",
            newCredentialBindingHash: Data([0x44, 0x44]),
            authorityHeadSequence: 1,
            authorityHeadHash: Data([0x55, 0x55]),
            preActiveCredentialCount: 1,
            capabilities: ["owner-auth-add-credential"],
            issuedAt: 1000,
            expiresAt: 1600,
            replayNonce: Data([0x33, 0x33])
        )
    }

    private static func result() -> OwnerWebauthnAddCredentialResult {
        OwnerWebauthnAddCredentialResult(
            credentialID: Data([0x99]),
            activeCredentialCount: 2
        )
    }
}
#endif
