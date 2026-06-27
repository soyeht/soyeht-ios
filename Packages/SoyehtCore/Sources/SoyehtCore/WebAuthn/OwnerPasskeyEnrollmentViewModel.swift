#if canImport(AuthenticationServices)
import Combine
import Foundation

/// Headless view-model for owner passkey **first enrollment** (SoyehtCore, SPM —
/// no SwiftUI, no app-target, no live `ASAuthorization`). The dedicated
/// enrollment screen observes `phase` and calls `enroll()` / `setUpLater()`.
///
/// It drives the ``OwnerPasskeyEnrollmentOrchestrator`` and, on failure, consults
/// the ``OwnerPasskeyRegistrationStatusClient`` to recover the committed-but-opaque
/// (E1) case — where the enrollment actually persisted server-side but the finish
/// ack was lost / returned an opaque 401.
///
/// Anti-oracle / fail-closed invariants (do not regress):
/// - The ONLY place a decision branches is a status **HTTP 200** (`enrolled`
///   true/false). The status client throws on non-200, so a `200` is implied by
///   a non-throwing `fetch()`.
/// - A status throw (opaque 401, network, decode) yields a **generic** failure —
///   never infer a reason from `BootstrapError.code`, and never blind re-enroll.
/// - `setUpLater()` is first-class and performs **no network**.
@MainActor
public final class OwnerPasskeyEnrollmentViewModel: ObservableObject {
    /// How an enrollment completed: a fresh registration this session, or a
    /// status check that revealed enrollment had already committed server-side
    /// (recovering a lost/opaque finish ack — the E1 case).
    public enum Completion: Equatable {
        case fresh(OwnerPasskeyEnrollmentResult)
        case alreadyCommitted
    }

    public enum Phase: Equatable {
        case idle
        case enrolling
        case completed(Completion)
        case skipped
        case failed(canRetry: Bool)
    }

    @Published public private(set) var phase: Phase = .idle

    private let performEnrollment: () async throws -> OwnerPasskeyEnrollmentResult
    private let fetchStatus: () async throws -> OwnerPasskeyRegistrationStatusResponse

    /// Production: drives the enrollment orchestrator and the status client.
    public init(
        orchestrator: OwnerPasskeyEnrollmentOrchestrator,
        statusClient: OwnerPasskeyRegistrationStatusClient
    ) {
        self.performEnrollment = { try await orchestrator.enroll() }
        self.fetchStatus = { try await statusClient.fetch() }
    }

    /// Designated initializer with injectable steps. `internal` — reachable only
    /// via `@testable import`, never public API.
    init(
        performEnrollment: @escaping () async throws -> OwnerPasskeyEnrollmentResult,
        fetchStatus: @escaping () async throws -> OwnerPasskeyRegistrationStatusResponse
    ) {
        self.performEnrollment = performEnrollment
        self.fetchStatus = fetchStatus
    }

    /// Run the enrollment ceremony. On success → `.completed(.fresh)`. On ANY
    /// failure, consult status to recover the committed-but-opaque case before
    /// surfacing a failure. Re-entrant calls while `.enrolling` are ignored.
    public func enroll() async {
        guard phase != .enrolling else { return }
        phase = .enrolling
        do {
            let result = try await performEnrollment()
            phase = .completed(.fresh(result))
        } catch {
            await resolveAfterEnrollmentFailure()
        }
    }

    /// First-class "set up later": no network, no enrollment.
    public func setUpLater() {
        phase = .skipped
    }

    /// After an enrollment failure, the ONLY recovery signal is a status 200:
    /// `enrolled == true` means the enrollment actually committed (recover as
    /// `.alreadyCommitted`); `false` means genuinely not enrolled (offer retry).
    /// Any status throw — opaque 401, network, decode — is a generic failure with
    /// retry; never inferred from the error, never a blind re-enroll.
    private func resolveAfterEnrollmentFailure() async {
        do {
            let status = try await fetchStatus()
            phase = status.enrolled ? .completed(.alreadyCommitted) : .failed(canRetry: true)
        } catch {
            phase = .failed(canRetry: true)
        }
    }
}
#endif
