import Foundation

enum MobileClawVPNOwnerPresentBoundaryError: Error, Equatable, Sendable {
    case consumed
    case invalidReview
    case invalidResult
}

enum MobileClawVPNOwnerPresentTarget: String, CaseIterable, Equatable, Sendable {
    case clawM = "Claw-M"
    case clawL = "Claw-L"
}

/// Sanitized, non-authoritative content for the future owner review surface.
/// The signed canonical context remains the authority; this summary deliberately
/// contains only fixed aliases and short correlation references, never member,
/// owner, household, real device/Claw identifiers, tuple, or proof bytes.
struct MobileClawVPNOwnerPresentReviewSummary: Equatable, Sendable {
    static let operation = "mobile-claw-vpn-dev-e2e-execute"
    static let deviceAlias = "Device-D"

    let target: MobileClawVPNOwnerPresentTarget
    let runReference: String
    let artifactReference: String
    let expiresAtUnixSeconds: UInt64

    fileprivate init(
        execution: MobileClawVPNDevE2EExecutionTupleV1,
        context: OwnerApprovalContextV2
    ) throws {
        try execution.validateShape()
        _ = try context.challengeDigest()
        let executionHash = try execution.executionHash()
        guard context.op == .mobileClawVPNDevE2EExecute,
              context.householdID == execution.householdID,
              context.mobileClawVPNExecutionHash == executionHash,
              context.issuedAt == execution.issuedAt,
              context.expiresAt == execution.expiresAt,
              let target = MobileClawVPNOwnerPresentTarget(rawValue: execution.clawAlias) else {
            throw MobileClawVPNOwnerPresentBoundaryError.invalidReview
        }
        self.target = target
        runReference = String(execution.executionRunID.prefix(8))
        artifactReference = execution.sourceArtifactGitSHA1
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        expiresAtUnixSeconds = context.expiresAt
    }
}

extension MobileClawVPNOwnerPresentReviewSummary: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "MobileClawVPNOwnerPresentReviewSummary(operation: \(Self.operation), "
            + "device: \(Self.deviceAlias), target: \(target.rawValue), "
            + "run: \(runReference), artifact: \(artifactReference), "
            + "expiresAtUnixSeconds: \(expiresAtUnixSeconds))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }
}

/// Count-only result returned after the sealed proof-mint action completes.
/// Capability tokens and real target identifiers remain inside the future adapter.
struct MobileClawVPNOwnerPresentSummary: Equatable, Sendable {
    let enrolledDeviceCount: Int
    let availableClawCount: Int
    let grantCount: Int
    let offerCount: Int
    let sessionCount: Int

    init(status: MobileClawVPNStatusResponse) throws {
        do {
            try MobileClawVPNResponseContract.validate(status, requiresConfigured: true)
        } catch {
            throw MobileClawVPNOwnerPresentBoundaryError.invalidResult
        }
        enrolledDeviceCount = status.enrolledDeviceCount
        availableClawCount = status.availableClawCount
        grantCount = status.grantCount
        offerCount = status.offerCount
        sessionCount = status.sessionCount
    }
}

extension MobileClawVPNOwnerPresentSummary: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "MobileClawVPNOwnerPresentSummary(enrolledDeviceCount: \(enrolledDeviceCount), "
            + "availableClawCount: \(availableClawCount), grantCount: \(grantCount), "
            + "offerCount: \(offerCount), sessionCount: \(sessionCount))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }
}

/// Shared terminal state for one asynchronous operation. `take()` clears the
/// closure under the lock before any await, so aliases and concurrent callers
/// observe the operation as spent even if the operation throws or is cancelled.
private final class MobileClawVPNOwnerPresentOneShot<Output: Sendable>: @unchecked Sendable {
    typealias Operation = @Sendable () async throws -> Output

    private let lock = NSLock()
    private var operation: Operation?

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func consume() async throws -> Output {
        let operation = try take()
        return try await operation()
    }

    private func take() throws -> Operation {
        lock.lock()
        defer { lock.unlock() }
        guard let operation else {
            throw MobileClawVPNOwnerPresentBoundaryError.consumed
        }
        self.operation = nil
        return operation
    }

    deinit {
        lock.lock()
        operation = nil
        lock.unlock()
    }
}

extension MobileClawVPNOwnerPresentOneShot: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String { "MobileClawVPNOwnerPresentOneShot(<redacted>)" }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["state": "<redacted>"], displayStyle: .class)
    }
}

/// Opaque operation-capability created only after finish succeeds. It is
/// noncopyable and has no token accessor, protocol conformance, or public
/// constructor. The future wire adapter will own any zeroizing proof storage;
/// this type-only slice never models proof bytes.
private struct MobileClawVPNOwnerPresentMintLease: ~Copyable {
    private let operation: MobileClawVPNOwnerPresentOneShot<MobileClawVPNOwnerPresentSummary>

    fileprivate init(
        operation: @escaping MobileClawVPNOwnerPresentOneShot<MobileClawVPNOwnerPresentSummary>.Operation
    ) {
        self.operation = MobileClawVPNOwnerPresentOneShot(operation: operation)
    }

    consuming func consume() async throws -> MobileClawVPNOwnerPresentSummary {
        try await operation.consume()
    }
}

private struct MobileClawVPNOwnerPresentPrepared: ~Copyable {
    let review: MobileClawVPNOwnerPresentReviewSummary
    private let operation: MobileClawVPNOwnerPresentOneShot<MobileClawVPNOwnerPresentSummary>

    fileprivate init(
        review: MobileClawVPNOwnerPresentReviewSummary,
        operation: @escaping MobileClawVPNOwnerPresentOneShot<MobileClawVPNOwnerPresentSummary>.Operation
    ) {
        self.review = review
        self.operation = MobileClawVPNOwnerPresentOneShot(operation: operation)
    }

    consuming func confirmAndMint() async throws -> MobileClawVPNOwnerPresentSummary {
        try await operation.consume()
    }
}

struct MobileClawVPNOwnerPresentStartBinding: Sendable {
    let execution: MobileClawVPNDevE2EExecutionTupleV1
    let approvalContext: OwnerApprovalContextV2
}

/// One pinned Engine session. The generic factory captures `context` once and
/// supplies that exact value to start, finish, and the sealed mint sink. The
/// prepared state and finish artifact remain lexical implementation details.
private final class MobileClawVPNOwnerPresentSession: @unchecked Sendable {
    private typealias Start = @Sendable (
        MobileClawVPNOwnerPresentTarget
    ) async throws -> MobileClawVPNOwnerPresentPrepared

    private let startOperation: Start

    private init(start: @escaping Start) {
        startOperation = start
    }

    func start(
        target: MobileClawVPNOwnerPresentTarget
    ) async throws -> MobileClawVPNOwnerPresentPrepared {
        try await startOperation(target)
    }

    fileprivate static func pinned<Context: Sendable, Prepared: Sendable, FinishArtifact: Sendable>(
        context: Context,
        start: @escaping @Sendable (
            Context,
            MobileClawVPNOwnerPresentTarget
        ) async throws -> (binding: MobileClawVPNOwnerPresentStartBinding, prepared: Prepared),
        finish: @escaping @Sendable (
            Context,
            Prepared,
            OwnerApprovalContextV2
        ) async throws -> FinishArtifact,
        mint: @escaping @Sendable (
            Context,
            FinishArtifact
        ) async throws -> MobileClawVPNOwnerPresentSummary
    ) -> MobileClawVPNOwnerPresentSession {
        MobileClawVPNOwnerPresentSession { target in
            let started = try await start(context, target)
            let review = try MobileClawVPNOwnerPresentReviewSummary(
                execution: started.binding.execution,
                context: started.binding.approvalContext
            )
            guard review.target == target else {
                throw MobileClawVPNOwnerPresentBoundaryError.invalidReview
            }
            return MobileClawVPNOwnerPresentPrepared(review: review) {
                try Task.checkCancellation()
                let artifact = try await finish(
                    context,
                    started.prepared,
                    started.binding.approvalContext
                )
                let lease = MobileClawVPNOwnerPresentMintLease {
                    try Task.checkCancellation()
                    return try await mint(context, artifact)
                }
                return try await lease.consume()
            }
        }
    }
}

/// Headless PRE-EFFECT state machine. It exposes only a sanitized review and a
/// count-only completion result. No production factory exists in this slice.
@MainActor
final class MobileClawVPNOwnerPresentCoordinator {
    enum Phase: Equatable {
        case idle
        case preparing
        case prepared(MobileClawVPNOwnerPresentReviewSummary)
        case executing
        case completed(MobileClawVPNOwnerPresentSummary)
        case failed(canRetry: Bool)
    }

    private(set) var phase: Phase = .idle

    private let session: MobileClawVPNOwnerPresentSession
    private var prepared: MobileClawVPNOwnerPresentPrepared?

    fileprivate init(session: MobileClawVPNOwnerPresentSession) {
        self.session = session
    }

    func prepare(target: MobileClawVPNOwnerPresentTarget) async {
        switch phase {
        case .idle, .failed:
            break
        case .preparing, .prepared, .executing, .completed:
            return
        }

        prepared = nil
        phase = .preparing
        do {
            try Task.checkCancellation()
            let next = try await session.start(target: target)
            try Task.checkCancellation()
            let review = next.review
            prepared = consume next
            phase = .prepared(review)
        } catch {
            prepared = nil
            phase = .failed(canRetry: true)
        }
    }

    func confirm() async {
        guard case .prepared = phase, let prepared = prepared.take() else {
            return
        }
        phase = .executing
        do {
            let summary = try await prepared.confirmAndMint()
            phase = .completed(summary)
        } catch {
            phase = .failed(canRetry: true)
        }
    }
}

#if DEBUG
/// The only constructor in this PRE-EFFECT slice. It is internal, DEBUG-only,
/// and exists solely so SoyehtCore tests can exercise the type boundary without
/// adding a production transport, route, app consumer, or authority factory.
enum MobileClawVPNOwnerPresentTestHarness {
    enum OneShotProbeOutcome: Equatable, Sendable {
        case success
        case consumed
        case failure
    }

    @MainActor
    static func makeCoordinator<Context: Sendable, Prepared: Sendable, FinishArtifact: Sendable>(
        context: Context,
        start: @escaping @Sendable (
            Context,
            MobileClawVPNOwnerPresentTarget
        ) async throws -> (binding: MobileClawVPNOwnerPresentStartBinding, prepared: Prepared),
        finish: @escaping @Sendable (
            Context,
            Prepared,
            OwnerApprovalContextV2
        ) async throws -> FinishArtifact,
        mint: @escaping @Sendable (
            Context,
            FinishArtifact
        ) async throws -> MobileClawVPNOwnerPresentSummary
    ) -> MobileClawVPNOwnerPresentCoordinator {
        MobileClawVPNOwnerPresentCoordinator(
            session: MobileClawVPNOwnerPresentSession.pinned(
                context: context,
                start: start,
                finish: finish,
                mint: mint
            )
        )
    }

    static func consumeOneShotConcurrently(
        operation: @escaping @Sendable () async throws -> Void
    ) async -> [OneShotProbeOutcome] {
        let oneShot = MobileClawVPNOwnerPresentOneShot(operation: operation)
        async let first = probe(oneShot)
        async let second = probe(oneShot)
        return await [first, second]
    }

    private static func probe(
        _ oneShot: MobileClawVPNOwnerPresentOneShot<Void>
    ) async -> OneShotProbeOutcome {
        do {
            try await oneShot.consume()
            return .success
        } catch MobileClawVPNOwnerPresentBoundaryError.consumed {
            return .consumed
        } catch {
            return .failure
        }
    }
}
#endif
