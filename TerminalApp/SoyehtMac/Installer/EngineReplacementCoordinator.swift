import Foundation
import SoyehtCore

/// One bounded replacement round, executed off the main thread. The journal
/// owns serialization across processes; the permit closes CREATE admission
/// during this round, including a resumed uncertain removal. Neither permits
/// a different target to overwrite an unresolved replacement.
struct EngineReplacementCoordinator {
    typealias Journal = EngineReplacementJournal

    enum Reason: Equatable {
        case preparationUnavailable, observationUnavailable, supervisorIncompatible
        case originalProcessChanged, removalPreconditionUnavailable, confirmationPending
        case journalUnavailable
    }

    enum Outcome: Equatable {
        case readyWithContinuity
        case readyAfterSupervisorRestart
        /// Preserve the journal and offer Resume. This is not evidence that
        /// the command failed, nor permission to create on the old engine.
        case unconfirmed(Reason)
    }

    enum EngineObservation {
        /// Both relevant launchd domains were positively observed absent.
        case absent
        case unknown
        /// Runtime identity and job configuration belong to the same observed
        /// process. A PID disagreement is unknown, not incompatibility.
        case present(EngineRuntimeIdentity, targetConfigurationMatches: Bool)
    }

    enum SupervisorObservation {
        /// Namespace, program/argv and OS peer PID were checked together.
        case verified(PTYSupervisorStatus)
        case unknown
        /// Reserved for an explicit wire contract mismatch.
        case incompatible
    }

    struct Observation {
        let engine: EngineObservation
        let supervisor: SupervisorObservation
    }

    final class CreationPermit {
        private let finish: (Outcome) -> Void
        private var finished = false
        init(finish: @escaping (Outcome) -> Void) { self.finish = finish }
        func release(_ outcome: Outcome) {
            precondition(!finished)
            finished = true
            finish(outcome)
        }
        deinit {
            // Losing an execution permit must not silently grant permission
            // to launch on a process whose removal is still uncertain.
            if !finished { finish(.unconfirmed(.confirmationPending)) }
        }
    }

    struct Operations {
        var acquireCreationPermit: () throws -> CreationPermit
        /// Re-read staged bytes, executable identity and plist digest against
        /// the journal. Preparing a different target is not recovery.
        var validatePreparedTarget: (Journal.Record) throws -> Void
        var observe: () -> Observation
        /// Runs with admission closed, immediately before removal. Includes
        /// legacy migration eligibility; a zero-session query alone is not a
        /// barrier against other clients creating sessions.
        var validateRemoval: (Journal.Record, EngineRuntimeIdentity) throws -> Void
        /// Bound to the engine's label by the adapter. No supervisor label is
        /// accepted by this interface.
        var removeEngine: () -> Void
        var loadPreparedEngine: () -> Void
        var waitBeforeObservation: () -> Void
    }

    let journal: Journal
    let operations: Operations
    var observationLimit = 6

    /// A nil proposal means Resume only: absence never manufactures a fresh
    /// operation. Read/write failures cannot authorize a launchctl mutation.
    func run(proposal: Journal.Record? = nil) -> Outcome {
        var outcome = Outcome.unconfirmed(.confirmationPending)
        let permit: CreationPermit
        do { permit = try operations.acquireCreationPermit() }
        catch { return .unconfirmed(.removalPreconditionUnavailable) }
        defer { permit.release(outcome) }

        do {
            let pending = try journal.read()
            guard var record = pending ?? proposal else {
                outcome = .unconfirmed(.journalUnavailable)
                return outcome
            }
            do { try operations.validatePreparedTarget(record) }
            catch {
                outcome = .unconfirmed(.preparationUnavailable)
                return outcome
            }
            if pending == nil { try journal.save(record) }

            var requestedRemoval = false
            var requestedLoad = false
            for index in 0..<max(1, observationLimit) {
                if index > 0 { operations.waitBeforeObservation() }
                let observation = operations.observe()
                let supervisor: PTYSupervisorStatus
                switch observation.supervisor {
                case let .verified(status): supervisor = status
                case .unknown:
                    outcome = .unconfirmed(.observationUnavailable)
                    continue
                case .incompatible:
                    outcome = .unconfirmed(.supervisorIncompatible)
                    return outcome
                }
                guard supervisor.protocolVersion == record.expectedArtifact.ptySupervisorProtocol else {
                    outcome = .unconfirmed(.supervisorIncompatible)
                    return outcome
                }

                switch observation.engine {
                case .unknown:
                    outcome = .unconfirmed(.observationUnavailable)
                case .absent:
                    guard record.phase != .completed, !requestedLoad else { continue }
                    record.phase = .awaitingLoad
                    try journal.save(record)
                    // As with removal, persistence precedes the command. A
                    // crash here leaves a safe load retry after proven absence.
                    record.phase = .awaitingReadback
                    try journal.save(record)
                    requestedLoad = true
                    operations.loadPreparedEngine()
                case let .present(runtime, targetConfigurationMatches):
                    guard let pid = runtime.processID, pid > 0,
                          let boot = runtime.processBootID, boot.utf8.count == 32,
                          boot.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                        outcome = .unconfirmed(.observationUnavailable)
                        continue
                    }
                    let isOriginal = runtime.processID == record.priorEnginePID
                        && runtime.processBootID == record.priorEngineBootID
                        && runtime.processID != nil && runtime.processBootID != nil
                    // After uncertain removal, the original can still answer
                    // while bootout is in flight. Even matching image/semver
                    // cannot turn that response into confirmation.
                    let canConfirm = record.phase == .prepared || record.phase == .completed || !isOriginal
                    if targetConfigurationMatches && canConfirm {
                        let readiness = runtime.supervisedReplacementOutcome(
                            expected: record.expectedArtifact,
                            priorBrokerBootID: record.priorBrokerBootID, supervisor: supervisor)
                        if readiness != .unconfirmed {
                            try journal.complete(record)
                            outcome = readiness == .readyWithContinuity ? .readyWithContinuity : .readyAfterSupervisorRestart
                            return outcome
                        }
                        if runtime.artifact?.compareImage(to: record.expectedArtifact) == .sameImage,
                           runtime.terminalBackend == "supervisor" {
                            // The expected engine is responding, but its
                            // broker readback may be unavailable or racing a
                            // restart. Re-observe; do not classify that as a
                            // different original process or remove it.
                            outcome = .unconfirmed(.confirmationPending)
                            continue
                        }
                    }
                    guard record.phase == .prepared || record.phase == .removalUncertain else { continue }
                    guard isOriginal else {
                        outcome = .unconfirmed(.originalProcessChanged)
                        return outcome
                    }
                    guard !requestedRemoval else { continue }
                    do { try operations.validateRemoval(record, runtime) }
                    catch {
                        outcome = .unconfirmed(.removalPreconditionUnavailable)
                        return outcome
                    }
                    record.phase = .removalUncertain
                    try journal.save(record)
                    requestedRemoval = true
                    operations.removeEngine()
                }
            }
        } catch {
            outcome = .unconfirmed(.journalUnavailable)
        }
        return outcome
    }
}
