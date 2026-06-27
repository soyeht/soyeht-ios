#if canImport(AuthenticationServices)
import Combine
import Foundation

/// Headless view-model for reviewing an owner approval-v2 operation before the
/// passkey gesture (SoyehtCore, SPM — no SwiftUI, no app-target, no live
/// `ASAuthorization`).
///
/// This first UI-facing slice is intentionally pair-machine-approve-only:
/// `prepare()` fetches the server start response and exposes its trusted context
/// for display; `confirm()` submits the SAME prepared bundle through
/// ``OwnerApprovalV2Orchestrator`` after the user explicitly approves.
///
/// Anti-oracle / WYSIWYS invariants (do not regress):
/// - The view reads only `phase`; it never receives or branches on an underlying
///   `BootstrapError`.
/// - The challenge stays inside the orchestrator and is never exposed here.
/// - `confirm()` only runs after a successful `prepare()` and uses the stored
///   prepared bundle, keeping cursor and context tied.
/// - Any start/assertion/approve failure collapses to `.failed(canRetry: true)`;
///   retry is manual and starts over with a fresh prepare.
@MainActor
public final class OwnerApprovalV2ReviewViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case preparing
        case prepared(OwnerApprovalContextV2)
        case confirming
        case completed
        case failed(canRetry: Bool)
    }

    @Published public private(set) var phase: Phase = .idle

    private var prepared: PreparedOwnerApprovalV2?
    private let performPrepare: () async throws -> PreparedOwnerApprovalV2
    private let performConfirm: (PreparedOwnerApprovalV2) async throws -> Void

    /// Production: prepares and confirms through the approval-v2 orchestrator.
    public init(cursor: UInt64, orchestrator: OwnerApprovalV2Orchestrator) {
        self.performPrepare = { try await orchestrator.prepare(cursor: cursor) }
        self.performConfirm = { prepared in try await orchestrator.confirm(prepared) }
    }

    /// Designated initializer with injectable steps. `internal` — reachable only
    /// via `@testable import`, never public API.
    init(
        prepare: @escaping () async throws -> PreparedOwnerApprovalV2,
        confirm: @escaping (PreparedOwnerApprovalV2) async throws -> Void
    ) {
        self.performPrepare = prepare
        self.performConfirm = confirm
    }

    /// Phase 1: fetch the trusted context for the UI to render. Performs no
    /// assertion and no approve. Re-entrant calls while preparing/confirming are
    /// ignored to avoid overlapping ceremonies.
    public func prepare() async {
        guard phase != .preparing, phase != .confirming else { return }
        phase = .preparing
        do {
            let prepared = try await performPrepare()
            guard prepared.startResponse.context.op == .pairMachineApprove else {
                self.prepared = nil
                phase = .failed(canRetry: true)
                return
            }
            self.prepared = prepared
            phase = .prepared(prepared.startResponse.context)
        } catch {
            prepared = nil
            phase = .failed(canRetry: true)
        }
    }

    /// Phase 2: after the user reviewed the context and tapped Approve, run the
    /// passkey assertion + approve using the stored prepared bundle. Errors are
    /// intentionally collapsed to one generic retryable failure.
    public func confirm() async {
        guard case .prepared = phase, let prepared else { return }
        phase = .confirming
        do {
            try await performConfirm(prepared)
            self.prepared = nil
            phase = .completed
        } catch {
            self.prepared = nil
            phase = .failed(canRetry: true)
        }
    }
}
#endif
