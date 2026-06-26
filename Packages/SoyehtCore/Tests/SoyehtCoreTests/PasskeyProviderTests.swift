#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation
import Testing

@testable import SoyehtCore

/// Unit tests for the app-target-free seams of ``PasskeyProvider``: request
/// construction and error mapping. The live ASAuthorization ceremony needs a
/// real authenticator + window + entitlement and is exercised manually on a
/// device target (S3c), not here.
@Suite struct PasskeyProviderTests {
    // MARK: makeRegistrationRequest field propagation

    @Test func makeRegistrationRequestPropagatesStandardFields() {
        let challenge = Data([0x01, 0x02, 0x03, 0x04])
        let userID = Data("owner-person-id".utf8)
        let request = OwnerPasskeyRegistrationRequest(
            relyingPartyIdentifier: "household.example",
            challenge: challenge,
            userID: userID,
            userName: "owner",
            userDisplayName: "Owner"
        )

        let asRequest = PasskeyProvider.makeRegistrationRequest(request)

        #expect(asRequest.relyingPartyIdentifier == "household.example")
        #expect(asRequest.challenge == challenge)
        #expect(asRequest.userID == userID)
        #expect(asRequest.name == "owner")
    }

    // MARK: error mapping

    @Test func mapsCanceledError() {
        #expect(PasskeyProvider.map(ASAuthorizationError(.canceled)) == .canceled)
    }

    @Test func mapsNotHandledError() {
        #expect(PasskeyProvider.map(ASAuthorizationError(.notHandled)) == .notHandled)
    }

    @Test func mapsInvalidResponseError() {
        #expect(PasskeyProvider.map(ASAuthorizationError(.invalidResponse)) == .invalidResponse)
    }

    @Test func mapsFailedErrorToFailedCase() {
        guard case .failed = PasskeyProvider.map(ASAuthorizationError(.failed)) else {
            Issue.record("expected .failed for ASAuthorizationError(.failed)")
            return
        }
    }

    @Test func mapsNonAuthServicesErrorToUnknown() {
        let error = NSError(
            domain: "test.passkey",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        guard case .unknown = PasskeyProvider.map(error) else {
            Issue.record("expected .unknown for a non-ASAuthorizationError")
            return
        }
    }

    // MARK: value-type round trips

    @Test func attestationIsValueEquatable() {
        let a = OwnerPasskeyAttestation(
            credentialID: Data([0x10]),
            attestationObject: Data([0x20]),
            clientDataJSON: Data([0x30])
        )
        let b = OwnerPasskeyAttestation(
            credentialID: Data([0x10]),
            attestationObject: Data([0x20]),
            clientDataJSON: Data([0x30])
        )
        #expect(a == b)
    }

    // MARK: cancellation (Option A seam: injected `performStart`, no UI/anchor)

    private static func sampleRequest() -> OwnerPasskeyRegistrationRequest {
        OwnerPasskeyRegistrationRequest(
            relyingPartyIdentifier: "household.example",
            challenge: Data([0x01]),
            userID: Data([0x02]),
            userName: "owner",
            userDisplayName: "Owner"
        )
    }

    private static func runRegister(
        _ provider: PasskeyProvider
    ) -> Task<OwnerPasskeyRegistrationError?, Never> {
        Task {
            do {
                _ = try await provider.register(sampleRequest())
                return nil
            } catch let error as OwnerPasskeyRegistrationError {
                return error
            } catch {
                return .unknown("unexpected: \(error)")
            }
        }
    }

    /// Cancelling the Task while the ceremony is in flight resolves `register(_:)`
    /// with `.canceled` (no real authenticator: `performStart` is stubbed to leave
    /// the continuation pending, so the anchor is never requested).
    @Test @MainActor func cancellingInFlightCeremonyResolvesWithCanceled() async {
        let relay = StartRelay()
        let provider = PasskeyProvider(
            anchorProvider: UnusedAnchorProvider(),
            performStart: { _ in relay.fire() }
        )

        let task = Self.runRegister(provider)
        await relay.waitForStart()  // continuation installed -> genuinely in flight
        task.cancel()

        #expect(await task.value == .canceled)
    }

    /// After a cancelled ceremony, a second `register(_:)` is allowed (state was
    /// cleared) rather than stuck at `.alreadyInProgress`. The first call is fully
    /// awaited (so `finish` has cleared state) before the second starts; the second
    /// reaching `performStart` proves it passed the guard, and it is cancelled too
    /// so no task is left alive.
    @Test @MainActor func registerAfterCancellationIsNotStuck() async {
        let relay = StartRelay()
        let provider = PasskeyProvider(
            anchorProvider: UnusedAnchorProvider(),
            performStart: { _ in relay.fire() }
        )

        let first = Self.runRegister(provider)
        await relay.waitForStart()
        first.cancel()
        #expect(await first.value == .canceled)

        let second = Self.runRegister(provider)
        await relay.waitForStart()  // would never fire if stuck at the .alreadyInProgress guard
        second.cancel()
        #expect(await second.value == .canceled)
    }

    /// A Task cancelled *before* `register(_:)` reaches the ceremony resolves with
    /// `.canceled` and never starts the platform request (no system sheet for an
    /// already-dead request). Guards the cancel-before-continuation race.
    @Test @MainActor func preCancelledTaskDoesNotStartAndReturnsCanceled() async {
        let release = StartRelay()
        let started = CallFlag()
        let provider = PasskeyProvider(
            anchorProvider: UnusedAnchorProvider(),
            performStart: { _ in started.markCalled() }
        )

        let task = Task { () -> OwnerPasskeyRegistrationError? in
            await release.waitForStart()  // park (ignores cancellation) until released
            do {
                _ = try await provider.register(Self.sampleRequest())
                return nil
            } catch let error as OwnerPasskeyRegistrationError {
                return error
            } catch {
                return .unknown("unexpected: \(error)")
            }
        }
        task.cancel()   // cancel while parked, before register() runs
        release.fire()  // now register() runs with Task.isCancelled == true

        #expect(await task.value == .canceled)
        #expect(started.wasCalled == false, "ceremony must not start for a pre-cancelled Task")
    }
}

/// Fails if the system ever asks for a presentation anchor — it must not, because
/// the cancellation tests stub `performStart` and never reach the live ceremony.
@MainActor
private final class UnusedAnchorProvider: PasskeyPresentationAnchorProviding {
    func passkeyPresentationAnchor() -> ASPresentationAnchor {
        fatalError("presentation anchor must not be requested when performStart is stubbed")
    }
}

/// Test-only sync: a stubbed `performStart` (on the main actor) calls `fire()` the
/// moment `register(_:)` has installed its continuation, letting the test cancel a
/// genuinely in-flight ceremony deterministically. Credits absorb fire-before-wait.
private final class StartRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var credits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        if waiters.isEmpty {
            credits += 1
            lock.unlock()
        } else {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume()
        }
    }

    func waitForStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if credits > 0 {
                credits -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Test-only flag recording whether the stubbed `performStart` ran.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func markCalled() {
        lock.lock()
        called = true
        lock.unlock()
    }

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }
}
#endif
