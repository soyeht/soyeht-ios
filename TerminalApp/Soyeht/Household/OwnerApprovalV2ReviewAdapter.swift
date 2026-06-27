#if os(iOS) && canImport(AuthenticationServices)
import Combine
import Foundation
import SoyehtCore

/// App-target adapter for the approval-v2 review screen.
///
/// The SPM view-model owns only the WYSIWYS approval-v2 ceremony. This adapter
/// preserves the iOS machine-join responsibilities that still live in the app:
/// snapshot pinning, queue lifecycle, and the local anchor pin required before
/// the engine finalizes the join.
@MainActor
final class OwnerApprovalV2ReviewAdapter: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case prepared(OwnerApprovalContextV2)
        case confirming
        case completed
        case cancelled
        case failed(canRetry: Bool)
    }

    typealias PinAnchorAction = (JoinRequestEnvelope) async throws -> Void
    typealias NowProvider = @Sendable () -> Date

    @Published private(set) var phase: Phase = .idle

    private let request: JoinRequestQueue.PendingRequest
    private let queue: JoinRequestQueue
    private let runtime: HouseholdMachineJoinRuntime
    private let reviewModel: OwnerApprovalV2ReviewViewModel
    private let pinAnchor: PinAnchorAction
    private let nowProvider: NowProvider
    private var confirmInFlight = false

    init(
        request: JoinRequestQueue.PendingRequest,
        queue: JoinRequestQueue,
        runtime: HouseholdMachineJoinRuntime,
        reviewModel: OwnerApprovalV2ReviewViewModel,
        nowProvider: @escaping NowProvider,
        pinAnchor: @escaping PinAnchorAction
    ) {
        self.request = request
        self.queue = queue
        self.runtime = runtime
        self.reviewModel = reviewModel
        self.nowProvider = nowProvider
        self.pinAnchor = pinAnchor
    }

    func prepare() async {
        guard canPrepare else { return }
        phase = .preparing
        await reviewModel.prepare()
        switch reviewModel.phase {
        case .prepared(let context):
            phase = .prepared(context)
        case .failed:
            phase = .failed(canRetry: true)
        default:
            phase = .failed(canRetry: true)
        }
    }

    func confirm() async {
        guard case .prepared = phase, !confirmInFlight else { return }
        confirmInFlight = true
        defer { confirmInFlight = false }

        runtime.beginConfirming(request)
        defer { runtime.endConfirming(request.envelope.idempotencyKey) }

        phase = .confirming
        guard let claimed = await queue.claim(
            idempotencyKey: request.envelope.idempotencyKey,
            now: nowProvider()
        ) else {
            phase = .failed(canRetry: false)
            return
        }

        do {
            // B7 external-anchor gate: this must complete before approve-v2,
            // because approve-v2 immediately drives the engine's finalize path.
            try await pinAnchor(claimed)
            await reviewModel.confirm()
            guard case .completed = reviewModel.phase else {
                throw OwnerApprovalV2ReviewAdapterError.confirmRejected
            }
            _ = await queue.confirmClaim(idempotencyKey: claimed.idempotencyKey, now: nowProvider())
            phase = .completed
        } catch {
            _ = await queue.failClaim(idempotencyKey: claimed.idempotencyKey, error: .networkDrop)
            phase = .failed(canRetry: false)
        }
    }

    func cancel() async {
        guard !confirmInFlight else { return }
        guard phase != .completed, phase != .cancelled else { return }
        _ = await queue.dismiss(idempotencyKey: request.envelope.idempotencyKey)
        runtime.endConfirming(request.envelope.idempotencyKey)
        phase = .cancelled
    }

    func tearDown() {
        runtime.endConfirming(request.envelope.idempotencyKey)
    }

    private var canPrepare: Bool {
        switch phase {
        case .idle:
            return true
        case .failed(let canRetry):
            return canRetry
        case .preparing, .prepared, .confirming, .completed, .cancelled:
            return false
        }
    }
}

private enum OwnerApprovalV2ReviewAdapterError: Error {
    case missingAnchorSecret
    case confirmRejected
}

extension OwnerApprovalV2ReviewAdapter {
    static func requireAndPinLocalAnchor(
        envelope: JoinRequestEnvelope,
        household: ActiveHouseholdState,
        transport: @escaping LocalAnchorClient.TransportPerform
    ) async throws {
        guard let anchorSecret = envelope.anchorSecret else {
            throw OwnerApprovalV2ReviewAdapterError.missingAnchorSecret
        }
        try await LocalAnchorClient(transport: transport).pinAnchor(
            candidateAddress: envelope.candidateAddress,
            anchorSecret: anchorSecret,
            householdId: household.householdId,
            householdPublicKey: household.householdPublicKey
        )
    }
}
#endif
