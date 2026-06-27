#if canImport(AuthenticationServices)
import Foundation
import Testing

@testable import SoyehtCore

/// Headless tests for `OwnerPasskeyEnrollmentViewModel` with injected steps (no
/// orchestrator/status-client wiring, no live `ASAuthorization`). Proves the
/// state machine + the status-recovery rules: success never consults status;
/// set-up-later does no network; any enrollment failure consults status; status
/// 200 enrolled true/false branches; a status throw is a generic failure with no
/// branch on `BootstrapError.code`; reentrant enroll is ignored.
@Suite struct OwnerPasskeyEnrollmentViewModelTests {
    private static func sampleResult() -> OwnerPasskeyEnrollmentResult {
        OwnerPasskeyEnrollmentResult(credentialID: Data([0xAB, 0xCD]), activeCredentialCount: 1)
    }

    private static func status(enrolled: Bool) -> OwnerPasskeyRegistrationStatusResponse {
        OwnerPasskeyRegistrationStatusResponse(version: 1, enrolled: enrolled)
    }

    /// Thread-safe call recorder for the injected steps.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _enroll = 0
        private var _status = 0
        func enroll() { lock.lock(); _enroll += 1; lock.unlock() }
        func status() { lock.lock(); _status += 1; lock.unlock() }
        var enrollCount: Int { lock.lock(); defer { lock.unlock() }; return _enroll }
        var statusCount: Int { lock.lock(); defer { lock.unlock() }; return _status }
    }

    private struct SampleError: Error {}

    /// A simple async gate to hold an enrollment mid-flight (reentrancy test).
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

    // MARK: success / skip

    @Test @MainActor func freshSuccessCompletesWithoutStatusCheck() async {
        let calls = Calls()
        let result = Self.sampleResult()
        let vm = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { calls.enroll(); return result },
            fetchStatus: { calls.status(); return Self.status(enrolled: false) }
        )

        await vm.enroll()

        #expect(vm.phase == .completed(.fresh(result)))
        #expect(calls.enrollCount == 1)
        #expect(calls.statusCount == 0)  // success never consults status
    }

    @Test @MainActor func setUpLaterSkipsWithoutNetwork() {
        let calls = Calls()
        let vm = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { calls.enroll(); return Self.sampleResult() },
            fetchStatus: { calls.status(); return Self.status(enrolled: false) }
        )

        vm.setUpLater()

        #expect(vm.phase == .skipped)
        #expect(calls.enrollCount == 0)
        #expect(calls.statusCount == 0)  // first-class skip, no network
    }

    // MARK: failure → status recovery

    @Test @MainActor func enrollmentFailureConsultsStatus() async {
        let calls = Calls()
        let vm = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { calls.enroll(); throw SampleError() },
            fetchStatus: { calls.status(); return Self.status(enrolled: false) }
        )

        await vm.enroll()

        #expect(calls.enrollCount == 1)
        #expect(calls.statusCount == 1)  // any enrollment failure consults status
    }

    @Test @MainActor func statusEnrolledTrueRecoversAsAlreadyCommitted() async {
        let vm = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { throw SampleError() },
            fetchStatus: { Self.status(enrolled: true) }
        )

        await vm.enroll()

        #expect(vm.phase == .completed(.alreadyCommitted))  // E1 recovery
    }

    @Test @MainActor func statusEnrolledFalseFailsWithRetry() async {
        let vm = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { throw SampleError() },
            fetchStatus: { Self.status(enrolled: false) }
        )

        await vm.enroll()

        #expect(vm.phase == .failed(canRetry: true))
    }

    @Test @MainActor func statusThrowFailsGenerically() async {
        let vm = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { throw SampleError() },
            fetchStatus: { throw BootstrapError.serverError(code: "unauthenticated", message: nil) }
        )

        await vm.enroll()

        #expect(vm.phase == .failed(canRetry: true))
    }

    /// Two DIFFERENT status errors produce the SAME generic failure — proves no
    /// branch on `BootstrapError.code` (anti-oracle).
    @Test @MainActor func statusFailureNeverBranchesOnErrorCode() async {
        let opaque401 = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { throw SampleError() },
            fetchStatus: { throw BootstrapError.serverError(code: "unauthenticated", message: nil) }
        )
        await opaque401.enroll()

        let otherError = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { throw SampleError() },
            fetchStatus: { throw SampleError() }
        )
        await otherError.enroll()

        #expect(opaque401.phase == .failed(canRetry: true))
        #expect(otherError.phase == .failed(canRetry: true))
        #expect(opaque401.phase == otherError.phase)  // identical regardless of error
    }

    // MARK: reentrancy

    /// A second `enroll()` while `.enrolling` is ignored (no duplicate ceremony).
    @Test @MainActor func reentrantEnrollWhileEnrollingIsIgnored() async {
        let calls = Calls()
        let gate = Gate()
        let result = Self.sampleResult()
        let vm = OwnerPasskeyEnrollmentViewModel(
            performEnrollment: { calls.enroll(); await gate.wait(); return result },
            fetchStatus: { calls.status(); return Self.status(enrolled: false) }
        )

        let first = Task { await vm.enroll() }
        while vm.phase != .enrolling { await Task.yield() }  // first is mid-flight, suspended

        await vm.enroll()  // ignored — already .enrolling
        await gate.open()
        await first.value

        #expect(calls.enrollCount == 1)  // the second call did not start a ceremony
        #expect(vm.phase == .completed(.fresh(result)))
    }
}
#endif
