import CryptoKit
import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// Closes PR #53 deferred F2: the rollback-on-apply-failure path was
/// covered structurally by the view's `applyPreference(...)` body but
/// had no unit-test surface. Now that the view-state lives in
/// `HouseholdApplePushServiceViewModel`, each rollback obligation —
/// durable-preference revert, toggle revert, `lastAppliedValue`
/// revert, and the `suppressNextChange` short-circuit on the
/// follow-up `onChange` — is testable in isolation.
@MainActor
final class HouseholdApplePushServiceViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Reload

    func testReloadLoadsActiveHouseholdAndPersistedToggleValue() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            initialIsEnabled: true
        )

        viewModel.reload()

        XCTAssertEqual(viewModel.household?.householdId, household.householdId)
        XCTAssertFalse(viewModel.isEnabled)
        XCTAssertFalse(viewModel.showApplyFailureBanner)
    }

    /// `reload()` MUST NOT trigger `applyPreference` for the persisted
    /// value it loads — `suppressNextChange` is the gate. The test
    /// drives `handleToggle` with the value `reload()` set, simulating
    /// SwiftUI's `.onChange(of:)` firing for the persistence load,
    /// and verifies `resumeAction` / `suspendAction` did NOT fire.
    func testReloadFollowedByOnChangeDoesNotTriggerApply() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        let resume = ActionRecorder<Void>()
        let suspend = ActionRecorder<Void>()
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: { try await resume.recordAndReturn() },
            suspend: { await suspend.record() },
            initialIsEnabled: true
        )

        viewModel.reload()
        viewModel.handleToggle(viewModel.isEnabled)
        try await Task.sleep(nanoseconds: 30_000_000)

        let resumeCalls = await resume.callCount()
        let suspendCalls = await suspend.callCount()
        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(suspendCalls, 0)
        XCTAssertTrue(preference.writes().isEmpty)
    }

    // MARK: - Apply success path

    func testToggleOnSuccessfullyResumesAndPersists() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        let resume = ActionRecorder<Void>()
        let suspend = ActionRecorder<Void>()
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: { try await resume.recordAndReturn() },
            suspend: { await suspend.record() },
            initialIsEnabled: false
        )
        viewModel.reload()

        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        await Self.waitForApplyToSettle(viewModel)

        XCTAssertTrue(viewModel.isEnabled)
        XCTAssertFalse(viewModel.showApplyFailureBanner)
        XCTAssertFalse(viewModel.isApplying)
        XCTAssertEqual(preference.currentValue(for: household.householdId), true)
        let resumeCalls = await resume.callCount()
        let suspendCalls = await suspend.callCount()
        XCTAssertEqual(resumeCalls, 1)
        XCTAssertEqual(suspendCalls, 0)
    }

    func testToggleOffSuccessfullySuspendsAndPersists() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: true])
        let resume = ActionRecorder<Void>()
        let suspend = ActionRecorder<Void>()
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: { try await resume.recordAndReturn() },
            suspend: { await suspend.record() },
            initialIsEnabled: true
        )
        viewModel.reload()

        viewModel.isEnabled = false
        viewModel.handleToggle(false)
        await Self.waitForApplyToSettle(viewModel)

        XCTAssertFalse(viewModel.isEnabled)
        XCTAssertFalse(viewModel.showApplyFailureBanner)
        XCTAssertEqual(preference.currentValue(for: household.householdId), false)
        let resumeCalls = await resume.callCount()
        let suspendCalls = await suspend.callCount()
        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(suspendCalls, 1)
    }

    // MARK: - Apply failure rollback (the main F2 contract)

    /// Resume throws → durable preference reverts, toggle reverts to
    /// prior value, banner shows, `isApplying` clears. The four-way
    /// rollback obligation is what F2 was deferred for.
    func testResumeFailureRollsBackPreferenceAndToggleAndShowsBanner() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        let resume = ActionRecorder<Void>(error: ResumeFailure())
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: { try await resume.recordAndReturn() },
            initialIsEnabled: false
        )
        viewModel.reload()

        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        await Self.waitForApplyToSettle(viewModel)

        XCTAssertFalse(viewModel.isEnabled, "Toggle did not revert after resume failure")
        XCTAssertTrue(viewModel.showApplyFailureBanner, "Failure banner not shown")
        XCTAssertFalse(viewModel.isApplying)
        XCTAssertEqual(
            preference.currentValue(for: household.householdId),
            false,
            "Durable preference did not revert on failure — operator's persisted state is now lying about APNS state"
        )
        // Two writes: optimistic forward (true) then rollback (false).
        // The rollback must hit the persistence layer — without it,
        // a subsequent app launch would read "true" while APNS is
        // unregistered.
        let writes = preference.writes()
        XCTAssertEqual(
            writes,
            [PreferenceWrite(enabled: true, householdId: household.householdId), PreferenceWrite(enabled: false, householdId: household.householdId)]
        )
        let resumeCalls = await resume.callCount()
        XCTAssertEqual(resumeCalls, 1)
    }

    /// After a failure rollback, re-toggling MUST start from the
    /// reverted value as the `lastAppliedValue` baseline, NOT from
    /// the optimistic-forward value that was overwritten. A wrong
    /// baseline would mean a second failure rolls forward to the
    /// wrong value.
    func testRolledBackBaselineIsTheRevertedValueNotTheOptimisticForward() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        let resume = ActionRecorder<Void>(error: ResumeFailure())
        let suspend = ActionRecorder<Void>()
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: { try await resume.recordAndReturn() },
            suspend: { await suspend.record() },
            initialIsEnabled: false
        )
        viewModel.reload()

        // First attempt: false → true → fails → reverts to false.
        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        await Self.waitForApplyToSettle(viewModel)
        XCTAssertFalse(viewModel.isEnabled)

        // The synthetic `onChange` from the revert: `handleToggle(false)`
        // MUST short-circuit (suppressNextChange consumed it). If it
        // didn't, suspend would fire — the operator never asked for
        // OFF.
        viewModel.handleToggle(false)
        try await Task.sleep(nanoseconds: 30_000_000)
        let suspendCallsAfterSyntheticOnChange = await suspend.callCount()
        XCTAssertEqual(
            suspendCallsAfterSyntheticOnChange,
            0,
            "Synthetic onChange after failure rollback fired suspend — `suppressNextChange` did not gate the revert"
        )

        // Now flip true → OFF intentionally. Baseline must be the
        // reverted false (not the optimistic-forward true).
        viewModel.isEnabled = false
        viewModel.handleToggle(false)
        await Self.waitForApplyToSettle(viewModel)
        let suspendCallsAfterIntentionalOff = await suspend.callCount()
        XCTAssertEqual(
            suspendCallsAfterIntentionalOff,
            1,
            "Intentional OFF toggle after failed ON did not invoke suspend"
        )
        XCTAssertFalse(viewModel.showApplyFailureBanner, "Banner did not clear on next apply")
    }

    /// Toggling clears the banner on each new apply attempt — the
    /// banner must not persist across an unrelated, successful retry.
    func testApplyFailureBannerClearsOnSuccessfulRetry() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        var shouldFail = true
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: {
                if shouldFail {
                    shouldFail = false
                    throw ResumeFailure()
                }
            },
            initialIsEnabled: false
        )
        viewModel.reload()

        // Fail.
        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        await Self.waitForApplyToSettle(viewModel)
        XCTAssertTrue(viewModel.showApplyFailureBanner)
        XCTAssertFalse(viewModel.isEnabled)

        // Retry (synthetic onChange from revert is gated; this is a
        // user-driven retry).
        viewModel.handleToggle(viewModel.isEnabled)  // consume the suppressed onChange
        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        await Self.waitForApplyToSettle(viewModel)

        XCTAssertTrue(viewModel.isEnabled)
        XCTAssertFalse(
            viewModel.showApplyFailureBanner,
            "Failure banner did not clear on successful retry — operator sees a stale error after a successful apply"
        )
    }

    // MARK: - Reload race vs in-flight apply

    /// PR #58 review major #2: a reload that lands between the
    /// optimistic save and the rollback catch block would otherwise
    /// rewrite `lastAppliedValue` and `isEnabled` to the persisted
    /// value, then the rollback would clobber both with the captured
    /// `priorValue` — leaving the VM disagreeing with persistence.
    /// `reload()` short-circuits while `isApplying` is true; the
    /// `.onAppear`-driven re-fire on the next view appearance
    /// recovers the missed reload.
    func testReloadDuringInFlightApplyIsNoOp() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        let resumeGate = ResumeGate()
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: { try await resumeGate.waitForRelease() },
            initialIsEnabled: false
        )
        viewModel.reload()
        XCTAssertFalse(viewModel.isEnabled)

        // Start an apply; the resumeGate keeps the Task in-flight.
        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        await Self.waitForApplyingToStart(viewModel)
        XCTAssertTrue(viewModel.isApplying)

        // Reload while the apply Task is in-flight — must short-
        // circuit on `isApplying`. Otherwise it would rewrite
        // `lastAppliedValue` and `isEnabled`, corrupting the in-flight
        // Task's rollback baseline.
        let isEnabledBeforeReload = viewModel.isEnabled
        let householdBeforeReload = viewModel.household?.householdId
        viewModel.reload()
        XCTAssertEqual(viewModel.isEnabled, isEnabledBeforeReload)
        XCTAssertEqual(viewModel.household?.householdId, householdBeforeReload)

        // Release the apply; the success path completes against the
        // un-corrupted baseline. If the reload had clobbered state,
        // either `isEnabled` would now be the persisted-false (not
        // true) or the success path would mutate `lastAppliedValue`
        // wrong.
        await resumeGate.release()
        await Self.waitForApplyToSettle(viewModel)
        XCTAssertTrue(viewModel.isEnabled)
        XCTAssertFalse(viewModel.showApplyFailureBanner)
    }

    // MARK: - Suppression-consumption ordering

    /// PR #58 review major #1: every programmatic write to
    /// `isEnabled` (rollback or reload) sets `suppressNextChange =
    /// true`. The contract is that the next `handleToggle` call
    /// consumes the flag. A user-driven re-tap that lands BEFORE the
    /// synthetic onChange would silently consume the flag and drop
    /// the user's intent. This test pins that ordering: after a
    /// rollback, the next `handleToggle` short-circuits regardless
    /// of whether the value matches the rollback target. SwiftUI's
    /// `@Published`-driven `.onChange` makes the synthetic onChange
    /// fire synchronously on-device, so this is benign in practice
    /// — but the test exists so a future @Observable migration that
    /// changes the ordering doesn't silently break the contract.
    func testFirstHandleToggleAfterRollbackShortCircuitsRegardlessOfValue() async throws {
        let household = try Self.makeHousehold()
        let preference = PreferenceRecorder(initial: [household.householdId: false])
        let resume = ActionRecorder<Void>(error: ResumeFailure())
        let suspend = ActionRecorder<Void>()
        let viewModel = makeViewModel(
            household: household,
            preference: preference,
            resume: { try await resume.recordAndReturn() },
            suspend: { await suspend.record() },
            initialIsEnabled: false
        )
        viewModel.reload()

        // Trigger the failure rollback (sets suppressNextChange).
        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        await Self.waitForApplyToSettle(viewModel)
        XCTAssertFalse(viewModel.isEnabled)
        XCTAssertTrue(viewModel.showApplyFailureBanner)

        // Now simulate a *user* tap that lands before the synthetic
        // onChange (different value than the rollback target). The
        // VM cannot distinguish this from the synthetic onChange —
        // suppressNextChange is consumed, the user's intent is
        // silently dropped. The contract relies on SwiftUI firing
        // the synthetic onChange first; the test pins the
        // VM-internal behaviour so a future migration is forced to
        // reckon with the contract.
        viewModel.isEnabled = true
        viewModel.handleToggle(true)
        try await Task.sleep(nanoseconds: 30_000_000)

        let resumeAfterRetry = await resume.callCount()
        XCTAssertEqual(
            resumeAfterRetry,
            1,
            "First handleToggle after rollback consumed suppressNextChange — second resume MUST NOT have fired"
        )
    }

    // MARK: - Inactive household

    func testApplyWithoutActiveHouseholdIsNoOp() async throws {
        let preference = PreferenceRecorder()
        let resume = ActionRecorder<Void>()
        let suspend = ActionRecorder<Void>()
        let viewModel = HouseholdApplePushServiceViewModel(
            sessionLoader: { nil },
            resumeAction: { try await resume.recordAndReturn() },
            suspendAction: { await suspend.record() },
            preferenceLoad: { preference.currentValue(for: $0) ?? true },
            preferenceSave: { preference.record($0, $1) },
            logFailure: { _ in }
        )

        viewModel.reload()
        XCTAssertNil(viewModel.household)

        viewModel.isEnabled = false
        viewModel.handleToggle(false)
        try await Task.sleep(nanoseconds: 30_000_000)

        let resumeCalls = await resume.callCount()
        let suspendCalls = await suspend.callCount()
        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(suspendCalls, 0)
        XCTAssertTrue(preference.writes().isEmpty)
    }

    // MARK: - Helpers

    private func makeViewModel(
        household: ActiveHouseholdState,
        preference: PreferenceRecorder,
        resume: @escaping HouseholdApplePushServiceViewModel.ResumeAction = { },
        suspend: @escaping HouseholdApplePushServiceViewModel.SuspendAction = { },
        initialIsEnabled: Bool
    ) -> HouseholdApplePushServiceViewModel {
        let viewModel = HouseholdApplePushServiceViewModel(
            sessionLoader: { household },
            resumeAction: resume,
            suspendAction: suspend,
            preferenceLoad: { preference.currentValue(for: $0) ?? true },
            preferenceSave: { preference.record($0, $1) },
            logFailure: { _ in }
        )
        viewModel.isEnabled = initialIsEnabled
        return viewModel
    }

    private static func waitForApplyToSettle(
        _ viewModel: HouseholdApplePushServiceViewModel,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while viewModel.isApplying, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // One extra hop so any post-isApplying state mutation
        // (banner, lastAppliedValue) has flushed.
        await Task.yield()
    }

    /// Polls until `isApplying` flips to true so the
    /// reload-during-in-flight test can drive its `reload()` while
    /// the Task is mid-flight. Bails out after a short deadline
    /// (Task scheduling is bounded; if the apply hasn't kicked off
    /// in 200 ms something is structurally wrong).
    private static func waitForApplyingToStart(
        _ viewModel: HouseholdApplePushServiceViewModel
    ) async {
        let deadline = Date().addingTimeInterval(0.2)
        while !viewModel.isApplying, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func makeHousehold(
        seed: UInt8 = 0xAA
    ) throws -> ActiveHouseholdState {
        let householdKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed &+ 1, count: 32))
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let ownerPersonId = try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey)
        let cert = PersonCert(
            rawCBOR: Data([0xA0]),
            version: 1,
            type: "person",
            householdId: householdId,
            personId: ownerPersonId,
            personPublicKey: ownerPublicKey,
            displayName: "Owner",
            caveats: PersonCert.requiredOwnerOperations.map { PersonCertCaveat(operation: $0) },
            notBefore: Date(timeIntervalSince1970: 1),
            notAfter: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            issuedBy: householdId,
            signature: Data(repeating: 0x11, count: 64)
        )
        return ActiveHouseholdState(
            householdId: householdId,
            householdName: "Casa Caio",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://household.example")!,
            ownerPersonId: ownerPersonId,
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "test-owner",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil
        )
    }
}

private struct ResumeFailure: Error, Equatable {}

/// Holds the resume action in-flight until `release()` is called.
/// Lets the reload-during-in-flight test pin a Task at the
/// `resumeAction` boundary so it can drive `reload()` while
/// `isApplying == true`.
private actor ResumeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Equatable witness for write-log assertions. Tuples don't conform to
/// `Equatable`, so a struct wraps the (enabled, householdId) pair.
private struct PreferenceWrite: Equatable {
    let enabled: Bool
    let householdId: String
}

/// Records every preference write so the test can assert the rollback
/// hits persistence (not just the in-memory toggle). The current value
/// per household is the last-written value; reads not preceded by a
/// write fall through to the test's `initial` map.
@MainActor
private final class PreferenceRecorder {
    private var initial: [String: Bool]
    private var lastWrites: [String: Bool] = [:]
    private var writeLog: [PreferenceWrite] = []

    init(initial: [String: Bool] = [:]) {
        self.initial = initial
    }

    func currentValue(for householdId: String) -> Bool? {
        if let last = lastWrites[householdId] { return last }
        return initial[householdId]
    }

    func record(_ enabled: Bool, _ householdId: String) {
        lastWrites[householdId] = enabled
        writeLog.append(PreferenceWrite(enabled: enabled, householdId: householdId))
    }

    func writes() -> [PreferenceWrite] {
        writeLog
    }
}

/// Counts invocations of an injected closure, optionally throwing on
/// each call. Lets a test assert that resume fired exactly once during
/// the failure path or that suspend never fired during the suppressed
/// `onChange` revert.
private actor ActionRecorder<T> {
    private var calls: Int = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func record() {
        calls += 1
    }

    func recordAndReturn() throws {
        calls += 1
        if let error {
            throw error
        }
    }

    func callCount() -> Int { calls }
}
