#if canImport(AuthenticationServices)
import Combine
import Foundation

/// Headless view-model for AddCredential backup passkey setup (SoyehtCore, SPM
/// only — no SwiftUI, no app-target, no live `ASAuthorization`).
///
/// The future UI observes `phase`: `prepare()` fetches the trusted AddCredential
/// context for display, and `confirm()` runs the stored prepared bundle through
/// the dual-ceremony orchestrator after explicit user intent.
///
/// Anti-oracle / WYSIWYS invariants:
/// - The view reads only `phase`; it never receives or branches on underlying
///   `BootstrapError` details.
/// - The top-level context is server-derived and is never recomputed client-side.
/// - `confirm()` only runs after successful `prepare()` and uses the stored
///   prepared bundle, keeping both challenges tied to the reviewed context.
/// - Any start/assertion/registration/finish failure collapses to one generic
///   retryable failure; retry starts over with a fresh prepare.
@MainActor
public final class OwnerWebauthnAddCredentialViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case preparing
        case prepared(OwnerApprovalContextV2)
        case confirming
        case completed(OwnerWebauthnAddCredentialResult)
        case failed(canRetry: Bool)
    }

    @Published public private(set) var phase: Phase = .idle

    private var prepared: PreparedOwnerWebauthnAddCredential?
    private let performPrepare: () async throws -> PreparedOwnerWebauthnAddCredential
    private let performConfirm: (PreparedOwnerWebauthnAddCredential) async throws -> OwnerWebauthnAddCredentialResult

    /// Production: prepares and confirms through the AddCredential orchestrator.
    public init(orchestrator: OwnerWebauthnAddCredentialOrchestrator) {
        self.performPrepare = { try await orchestrator.prepare() }
        self.performConfirm = { prepared in try await orchestrator.confirm(prepared) }
    }

    /// Designated initializer with injectable steps. `internal` — reachable only
    /// via `@testable import`, never public API.
    init(
        prepare: @escaping () async throws -> PreparedOwnerWebauthnAddCredential,
        confirm: @escaping (PreparedOwnerWebauthnAddCredential) async throws -> OwnerWebauthnAddCredentialResult
    ) {
        self.performPrepare = prepare
        self.performConfirm = confirm
    }

    /// Phase 1: fetch the server context for UI review. Performs no assertion,
    /// no registration, and no finish. Re-entrant calls while busy are ignored.
    public func prepare() async {
        guard phase != .preparing, phase != .confirming else { return }
        phase = .preparing
        do {
            let prepared = try await performPrepare()
            guard prepared.startResponse.context.op == .addCredential else {
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

    /// Phase 2: after review, run the two passkey ceremonies and finish with the
    /// stored prepared bundle. Errors are intentionally collapsed to one generic
    /// retryable failure and the stale prepared bundle is discarded.
    public func confirm() async {
        guard case .prepared = phase, let prepared else { return }
        phase = .confirming
        do {
            let result = try await performConfirm(prepared)
            self.prepared = nil
            phase = .completed(result)
        } catch {
            self.prepared = nil
            phase = .failed(canRetry: true)
        }
    }
}
#endif
